//! SDL3 + TinySoundFont music backend: exports DG_music_module (doom/i_sound.h). RegisterSong
//! copies the MUS lump; a second SDL audio device stream pulls from a callback that walks the
//! MUS sequencer (src/mus.zig) and renders through tsf with the embedded GM soundfont. SDL
//! mixes this logical device with the SFX module's stream.

const std = @import("std");
const sdl = @import("sdl");
const tsf = @import("tsf");
const doom = @import("interop");
const mus = @import("mus.zig");
const soundfont = @import("soundfont");

const errify = @import("sdl.zig").errify;

const SAMPLE_RATE = 44100; // matches the SFX module
const MUS_TICK_RATE = 140; // MUS delay ticks per second
const SAMPLES_PER_TICK = SAMPLE_RATE / MUS_TICK_RATE; // 315 exactly

const allocator = std.heap.c_allocator;

/// A registered song: owned copy of the MUS lump (the engine may release the WAD lump while the
/// song still plays) + its validated score slice.
const Song = struct {
    data: []u8,
    score: []const u8,
};

var synth: ?*tsf.tsf = null;
var stream: ?*sdl.SDL_AudioStream = null;

// Playback state: the game thread mutates it under SDL_LockAudioStream; the callback (audio
// thread) reads/advances it. SDL holds the stream lock while the callback runs, same model as
// sdl_sound.zig.
var current: ?*Song = null;
var seq: mus.Sequencer = undefined;
var looping = false;
var playing = false;

var music_devices = [_]doom.SndDevice{
    doom.SNDDEVICE_PAS,
    doom.SNDDEVICE_GUS,
    doom.SNDDEVICE_WAVEBLASTER,
    doom.SNDDEVICE_SOUNDCANVAS,
    doom.SNDDEVICE_GENMIDI,
    doom.SNDDEVICE_AWE32,
};

// ---------------------------------------------------------------------------
// MUS event -> tsf mapping
// ---------------------------------------------------------------------------

/// MUS channel -> MIDI/tsf channel: 15 is percussion -> 9; 9-14 shift up to dodge MIDI's drum
/// channel (same mapping family as mus2mid.c).
fn mapChannel(ch: u8) c_int {
    return switch (ch) {
        15 => 9,
        9...14 => @as(c_int, ch) + 1,
        else => ch,
    };
}

/// MUS controller number -> MIDI CC (controller_map in doom/mus2mid.c). Index 0 (program
/// change) is handled separately.
const midi_cc = [_]u8{ 0x00, 0x20, 0x01, 0x07, 0x0A, 0x0B, 0x5B, 0x5D, 0x40, 0x43 };

fn applyEvent(f: *tsf.tsf, ev: mus.Event) void {
    switch (ev) {
        .note_on => |e| _ = tsf.tsf_channel_note_on(
            f,
            mapChannel(e.ch),
            e.note,
            @as(f32, @floatFromInt(e.vol)) / 127.0,
        ),
        .note_off => |e| _ = tsf.tsf_channel_note_off(f, mapChannel(e.ch), e.note),
        // 128 -> 8192 (centered), standard +/-2 semitone range; mus2mid math.
        .pitch_bend => |e| _ = tsf.tsf_channel_set_pitchwheel(f, mapChannel(e.ch), @as(c_int, e.value) * 64),
        .program_change => |e| _ = tsf.tsf_channel_set_presetnumber(
            f,
            mapChannel(e.ch),
            e.preset,
            @intFromBool(e.ch == 15),
        ),
        .controller => |e| _ = tsf.tsf_channel_midi_control(f, mapChannel(e.ch), midi_cc[e.ctrl], e.value),
        .system => |e| switch (e.kind) {
            10 => _ = tsf.tsf_channel_sounds_off_all(f, mapChannel(e.ch)),
            11 => _ = tsf.tsf_channel_note_off_all(f, mapChannel(e.ch)),
            14 => _ = tsf.tsf_channel_midi_control(f, mapChannel(e.ch), 121, 0), // reset all ctrl
            else => {}, // 12/13 (mono/poly mode): no-op for a soundfont synth
        },
        .end_of_score => if (looping and current != null) {
            allNotesOff(f);
            seq.reset();
        } else {
            playing = false; // keep rendering so voices decay naturally
        },
    }
}

fn allNotesOff(f: *tsf.tsf) void {
    var ch: c_int = 0;
    while (ch < 16) : (ch += 1) _ = tsf.tsf_channel_note_off_all(f, ch);
}

// ---------------------------------------------------------------------------
// Audio-thread rendering
// ---------------------------------------------------------------------------

var scratch: [2048]f32 = undefined; // 1024 stereo frames (~23ms) per chunk

fn musicCallback(
    userdata: ?*anyopaque,
    s: ?*sdl.SDL_AudioStream,
    additional_amount: c_int,
    total_amount: c_int,
) callconv(.c) void {
    _ = userdata;
    _ = total_amount;
    const frame_bytes = 2 * @sizeOf(f32);
    var remaining: usize = @intCast(@max(additional_amount, 0));
    while (remaining >= frame_bytes) {
        const frames: usize = @min(remaining / frame_bytes, scratch.len / 2);
        renderFrames(scratch[0 .. frames * 2]);
        _ = sdl.SDL_PutAudioStreamData(s, &scratch, @intCast(frames * frame_bytes));
        remaining -= frames * frame_bytes;
    }
}

/// Fill `buf` (f32 stereo interleaved): fire due sequencer events, render
/// until the next one. tsf renders silence + decaying voices when idle.
fn renderFrames(buf: []f32) void {
    const f = synth orelse {
        @memset(buf, 0);
        return;
    };
    const frames = buf.len / 2;
    var i: usize = 0;
    while (i < frames) {
        var n = frames - i;
        if (current != null and playing) {
            // Bounded drain: a pathological score with no delays would
            // otherwise loop forever via end_of_score -> reset -> replay.
            var fired: usize = 0;
            while (seq.popEvent()) |ev| {
                applyEvent(f, ev);
                fired += 1;
                if (fired > 10_000) {
                    playing = false;
                    break;
                }
            }
            const due = seq.advance(n);
            if (due > 0) n = due;
        }
        _ = tsf.tsf_render_float(f, buf[i * 2 ..].ptr, @intCast(n), 0);
        i += n;
    }
}

// ---------------------------------------------------------------------------
// DG_music_module callbacks (game thread)
// ---------------------------------------------------------------------------

fn musicInit() callconv(.c) doom.boolean {
    init() catch {
        std.log.err("music init failed: {s}", .{sdl.SDL_GetError()});
        return doom.FALSE; // engine runs without music, never fatal
    };
    return doom.TRUE;
}

fn init() !void {
    const f = tsf.tsf_load_memory(soundfont.data, soundfont.data.len) orelse {
        std.log.err("music: failed to parse embedded soundfont", .{});
        return error.SoundfontLoad;
    };
    tsf.tsf_set_output(f, tsf.TSF_STEREO_INTERLEAVED, SAMPLE_RATE, 0);
    synth = f;
    errdefer {
        tsf.tsf_close(f);
        synth = null;
    }
    try errify(sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO));
    errdefer sdl.SDL_QuitSubSystem(sdl.SDL_INIT_AUDIO);
    const spec: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_F32, .channels = 2, .freq = SAMPLE_RATE };
    stream = try errify(sdl.SDL_OpenAudioDeviceStream(
        sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &spec,
        musicCallback,
        null,
    ));
    // The device starts paused.
    try errify(sdl.SDL_ResumeAudioStreamDevice(stream));
}

fn musicShutdown() callconv(.c) void {
    if (stream) |s| {
        sdl.SDL_DestroyAudioStream(s); // also closes its logical device
        stream = null;
        sdl.SDL_QuitSubSystem(sdl.SDL_INIT_AUDIO);
    }
    if (synth) |f| {
        tsf.tsf_close(f);
        synth = null;
    }
    // Registered songs are freed via UnRegisterSong; anything left leaks
    // intentionally (process exit).
}

fn musicSetVolume(volume: c_int) callconv(.c) void {
    const s = stream orelse return;
    const v = std.math.clamp(volume, 0, 127);
    _ = sdl.SDL_SetAudioStreamGain(s, @as(f32, @floatFromInt(v)) / 127.0);
}

fn musicPause() callconv(.c) void {
    const s = stream orelse return;
    _ = sdl.SDL_PauseAudioStreamDevice(s);
}

fn musicResume() callconv(.c) void {
    const s = stream orelse return;
    _ = sdl.SDL_ResumeAudioStreamDevice(s);
}

fn musicRegisterSong(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    if (stream == null or data == null or len <= 0) return null;
    const bytes = @as([*]const u8, @ptrCast(data.?))[0..@intCast(len)];
    _ = mus.parseScore(bytes) catch {
        std.log.warn("music: lump is not MUS format (MIDI from a PWAD?), skipping", .{});
        return null;
    };
    const song = allocator.create(Song) catch return null;
    const copy = allocator.dupe(u8, bytes) catch {
        allocator.destroy(song);
        return null;
    };
    song.* = .{
        .data = copy,
        .score = mus.parseScore(copy) catch unreachable, // validated above
    };
    return song;
}

fn musicUnRegisterSong(handle: ?*anyopaque) callconv(.c) void {
    const song: *Song = @ptrCast(@alignCast(handle orelse return));
    if (stream) |s| {
        _ = sdl.SDL_LockAudioStream(s);
        if (current == song) {
            // The engine stops before unregistering; guard anyway.
            current = null;
            playing = false;
        }
        _ = sdl.SDL_UnlockAudioStream(s);
    }
    allocator.free(song.data);
    allocator.destroy(song);
}

fn musicPlaySong(handle: ?*anyopaque, looping_: doom.boolean) callconv(.c) void {
    const song: *Song = @ptrCast(@alignCast(handle orelse return));
    const s = stream orelse return;
    const f = synth orelse return;
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    tsf.tsf_reset(f);
    _ = tsf.tsf_channel_set_bank_preset(f, 9, 128, 0); // GM percussion on ch 9
    current = song;
    seq = mus.Sequencer.init(song.score, SAMPLES_PER_TICK);
    looping = looping_ != 0;
    playing = true;
}

fn musicStopSong() callconv(.c) void {
    const s = stream orelse return;
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    if (synth) |f| allNotesOff(f);
    current = null;
    playing = false;
}

fn musicIsPlaying() callconv(.c) doom.boolean {
    const s = stream orelse return doom.FALSE;
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    return if (playing) doom.TRUE else doom.FALSE;
}

export var DG_music_module: doom.MusicModule = .{
    .sound_devices = &music_devices,
    .num_sound_devices = music_devices.len,
    .Init = musicInit,
    .Shutdown = musicShutdown,
    .SetMusicVolume = musicSetVolume,
    .PauseMusic = musicPause,
    .ResumeMusic = musicResume,
    .RegisterSong = musicRegisterSong,
    .UnRegisterSong = musicUnRegisterSong,
    .PlaySong = musicPlaySong,
    .StopSong = musicStopSong,
    .MusicIsPlaying = musicIsPlaying,
    .Poll = null,
};
