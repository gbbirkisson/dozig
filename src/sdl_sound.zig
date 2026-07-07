//! SDL3 sound-effects backend: exports DG_sound_module (doom/i_sound.h). One SDL_AudioStream
//! feeds the default playback device; a pull callback on SDL's audio thread mixes the 16 Doom
//! channels, so volume/separation/pitch stay live while a sound plays. Cached sounds are f32
//! mono @ SAMPLE_RATE, converted once on first play and kept forever.

const std = @import("std");
const sdl = @import("sdl");
const doom = @import("interop");

const errify = @import("sdl.zig").errify;

// Link-compat shims: under FEATURE_SOUND, i_sound.c binds these config variables
// (M_BindVariable), whose C definitions live in i_sdlsound.c — which the Zig build does not
// compile. Never read by this implementation.
export var use_libsamplerate: c_int = 0;
export var libsamplerate_scale: f32 = 0.65;

const NUM_CHANNELS = 16; // fixed by the engine (s_sound.c channel allocator)
const SAMPLE_RATE = 44100; // matches snd_samplerate default in i_sound.c
const NORM_PITCH = 128; // vanilla: pitch 128 = unshifted playback

const allocator = std.heap.c_allocator;

var use_sfx_prefix = false;

/// A sound converted to f32 mono @ SAMPLE_RATE. Allocated once on first play, pointed to by
/// sfxinfo.driver_data, never freed (no eviction).
const CachedSound = struct {
    samples: []f32,
};

/// Lump name for a sound: "ds" + name when use_sfx_prefix (true for Doom), following the link
/// for linked sounds (e.g. chgun -> pistol). Mirrors GetSfxLumpName (doom/i_sdlsound.c).
fn lumpName(sfx_in: *doom.SfxInfo, buf: []u8) ?[:0]const u8 {
    const sfx = sfx_in.link orelse sfx_in;
    const name = std.mem.sliceTo(&sfx.name, 0);
    return if (use_sfx_prefix)
        std.fmt.bufPrintSentinel(buf, "ds{s}", .{name}, 0) catch null
    else
        std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch null;
}

/// Convert DMX PCM (unsigned 8-bit mono @ rate) to f32 mono @ SAMPLE_RATE. SDL_AudioStream does
/// the resampling with proper filtering, replacing the C backend's hand-rolled expansion +
/// low-pass (doom/i_sdlsound.c:531-619).
fn convertPcm(pcm: []const u8, rate: c_int) ![]f32 {
    const src: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_U8, .channels = 1, .freq = rate };
    const dst: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_F32, .channels = 1, .freq = SAMPLE_RATE };
    const conv = try errify(sdl.SDL_CreateAudioStream(&src, &dst));
    defer sdl.SDL_DestroyAudioStream(conv);
    try errify(sdl.SDL_PutAudioStreamData(conv, pcm.ptr, @intCast(pcm.len)));
    try errify(sdl.SDL_FlushAudioStream(conv));
    const avail = try errify(sdl.SDL_GetAudioStreamAvailable(conv));
    const count = @as(usize, @intCast(avail)) / @sizeOf(f32);
    if (count == 0) return error.SdlError;
    const samples = try allocator.alloc(f32, count);
    errdefer allocator.free(samples);
    const got = try errify(sdl.SDL_GetAudioStreamData(conv, samples.ptr, @intCast(count * @sizeOf(f32))));
    if (@as(usize, @intCast(got)) != count * @sizeOf(f32)) return error.SdlError;
    return samples;
}

/// Get the converted samples for a sound, loading and converting on first use. DMX format
/// (doom/i_sdlsound.c:624-696): 8-byte header (magic 0x03 0x00, u16le sample rate, u32le sample
/// count), 16 junk/padding bytes at each end of the PCM data. Returns null for invalid lumps
/// (engine just skips the sound, like the C backend).
fn cacheSound(sfx: *doom.SfxInfo) ?*CachedSound {
    if (sfx.driver_data) |ptr| return @ptrCast(@alignCast(ptr));

    // s_sound.c resolves sfx.lumpnum via I_GetSfxLumpNum before I_StartSound
    // (doom/s_sound.c:470-472), so it is valid here.
    const lump = sfx.lumpnum;
    const raw = doom.W_CacheLumpNum(lump, doom.PU_STATIC) orelse return null;
    defer doom.W_ReleaseLumpNum(lump);
    const lumplen: usize = @intCast(doom.W_LumpLength(@intCast(lump)));
    const data = @as([*]const u8, @ptrCast(raw))[0..lumplen];

    if (data.len < 8 or data[0] != 0x03 or data[1] != 0x00) return null;
    const rate = std.mem.readInt(u16, data[2..4], .little);
    const length = std.mem.readInt(u32, data[4..8], .little);
    // Reject header length beyond the lump, and DMX's <= 48-sample minimum.
    if (length > data.len - 8 or length <= 48) return null;
    const pcm = data[8 + 16 ..][0 .. length - 32];

    const samples = convertPcm(pcm, rate) catch {
        std.log.warn("sfx '{s}': conversion failed: {s}", .{ std.mem.sliceTo(&sfx.name, 0), sdl.SDL_GetError() });
        return null;
    };
    const snd = allocator.create(CachedSound) catch {
        allocator.free(samples);
        return null;
    };
    snd.* = .{ .samples = samples };
    sfx.driver_data = snd;
    return snd;
}

/// Per-channel playback state. Written by the game thread under SDL_LockAudioStream;
/// read/advanced by the audio thread in mixCallback (SDL holds the stream lock while the
/// callback runs, so the lock fully serializes the two threads).
const Channel = struct {
    samples: []const f32 = &.{},
    pos: f64 = 0, // fractional sample position (advances by step)
    step: f32 = 1.0, // pitch / NORM_PITCH; 1.0 = unshifted
    lgain: f32 = 0,
    rgain: f32 = 0,
    active: bool = false,
};

var channels: [NUM_CHANNELS]Channel = @splat(.{});
var stream: ?*sdl.SDL_AudioStream = null;

/// Audio-thread scratch buffer: 1024 stereo frames (~23ms @ 44.1kHz) per chunk, looping until
/// the request is filled. Static so the audio thread never allocates.
var scratch: [2048]f32 = undefined;

fn mixCallback(
    userdata: ?*anyopaque,
    s: ?*sdl.SDL_AudioStream,
    additional_amount: c_int,
    total_amount: c_int,
) callconv(.c) void {
    _ = userdata;
    _ = total_amount;
    const frame_bytes = 2 * @sizeOf(f32); // f32 stereo
    var remaining: usize = @intCast(@max(additional_amount, 0));
    while (remaining >= frame_bytes) {
        // Note the explicit type: @min with a comptime bound (1024) narrows
        // the result type to u11, which `frames * 2` then overflows.
        const frames: usize = @min(remaining / frame_bytes, scratch.len / 2);
        const buf = scratch[0 .. frames * 2];
        @memset(buf, 0);
        for (&channels) |*ch| {
            if (!ch.active) continue;
            for (0..frames) |i| {
                const idx: usize = @intFromFloat(ch.pos);
                if (idx + 1 >= ch.samples.len) {
                    ch.active = false;
                    break;
                }
                // Linear interpolation: needed once step != 1.0 (pitch).
                const frac: f32 = @floatCast(ch.pos - @floor(ch.pos));
                const sample = ch.samples[idx] * (1 - frac) + ch.samples[idx + 1] * frac;
                buf[i * 2] += sample * ch.lgain;
                buf[i * 2 + 1] += sample * ch.rgain;
                ch.pos += ch.step;
            }
        }
        _ = sdl.SDL_PutAudioStreamData(s, buf.ptr, @intCast(frames * frame_bytes));
        remaining -= frames * frame_bytes;
    }
}

fn sfxInit(prefix: doom.boolean) callconv(.c) doom.boolean {
    use_sfx_prefix = prefix != 0;
    init() catch {
        std.log.err("sound init failed: {s}", .{sdl.SDL_GetError()});
        return doom.FALSE; // engine stays silent, never fatal
    };
    return doom.TRUE;
}

fn init() !void {
    try errify(sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO));
    errdefer sdl.SDL_QuitSubSystem(sdl.SDL_INIT_AUDIO);
    const spec: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_F32, .channels = 2, .freq = SAMPLE_RATE };
    stream = try errify(sdl.SDL_OpenAudioDeviceStream(
        sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &spec,
        mixCallback,
        null,
    ));
    // The device starts paused.
    try errify(sdl.SDL_ResumeAudioStreamDevice(stream));
}

fn sfxShutdown() callconv(.c) void {
    if (stream) |s| {
        sdl.SDL_DestroyAudioStream(s); // also closes the device it opened
        stream = null;
        sdl.SDL_QuitSubSystem(sdl.SDL_INIT_AUDIO);
    }
    // Cached sounds are intentionally leaked: process is exiting.
}

fn sfxGetLumpNum(sfx: *doom.SfxInfo) callconv(.c) c_int {
    var buf: [16]u8 = undefined;
    const name = lumpName(sfx, &buf) orelse return -1;
    return doom.W_GetNumForName(name.ptr);
}

fn sfxUpdate() callconv(.c) void {}

/// Volume/separation -> left/right gains, identical math to I_SDL_UpdateSoundParams
/// (doom/i_sdlsound.c:810-816). vol is 0..127, sep is 0..254 (127 = centered); both pre-clamped
/// by i_sound.c.
fn gains(vol: c_int, sep: c_int) struct { l: f32, r: f32 } {
    const left = std.math.clamp(@divTrunc((254 - sep) * vol, 127), 0, 255);
    const right = std.math.clamp(@divTrunc(sep * vol, 127), 0, 255);
    return .{
        .l = @as(f32, @floatFromInt(left)) / 255.0,
        .r = @as(f32, @floatFromInt(right)) / 255.0,
    };
}

fn sfxUpdateParams(channel: c_int, vol: c_int, sep: c_int) callconv(.c) void {
    const s = stream orelse return;
    if (channel < 0 or channel >= NUM_CHANNELS) return;
    const g = gains(vol, sep);
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    channels[@intCast(channel)].lgain = g.l;
    channels[@intCast(channel)].rgain = g.r;
}

fn sfxStart(sfx: *doom.SfxInfo, channel: c_int, vol: c_int, sep: c_int) callconv(.c) c_int {
    const s = stream orelse return -1;
    if (channel < 0 or channel >= NUM_CHANNELS) return -1;
    const snd = cacheSound(sfx) orelse return -1;
    // Vanilla link pitch (S_StartSoundAtVolume): linked sounds play at the pitch stored on the
    // linking entry — chgun = pistol @ 150/128 (doom/sounds.c:205). The SDL2 backend dropped
    // this; we restore it.
    const pitch: f32 = if (sfx.link != null) @floatFromInt(sfx.pitch) else NORM_PITCH;
    const g = gains(vol, sep);
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    channels[@intCast(channel)] = .{
        .samples = snd.samples,
        .pos = 0,
        .step = pitch / NORM_PITCH,
        .lgain = g.l,
        .rgain = g.r,
        .active = true,
    };
    return channel;
}

fn sfxStop(channel: c_int) callconv(.c) void {
    const s = stream orelse return;
    if (channel < 0 or channel >= NUM_CHANNELS) return;
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    channels[@intCast(channel)].active = false;
}

fn sfxIsPlaying(channel: c_int) callconv(.c) doom.boolean {
    const s = stream orelse return doom.FALSE;
    if (channel < 0 or channel >= NUM_CHANNELS) return doom.FALSE;
    _ = sdl.SDL_LockAudioStream(s);
    defer _ = sdl.SDL_UnlockAudioStream(s);
    return if (channels[@intCast(channel)].active) doom.TRUE else doom.FALSE;
}

var sfx_devices = [_]doom.SndDevice{
    doom.SNDDEVICE_SB,
    doom.SNDDEVICE_PAS,
    doom.SNDDEVICE_GUS,
    doom.SNDDEVICE_WAVEBLASTER,
    doom.SNDDEVICE_SOUNDCANVAS,
    doom.SNDDEVICE_AWE32,
};

export var DG_sound_module: doom.SoundModule = .{
    .sound_devices = &sfx_devices,
    .num_sound_devices = sfx_devices.len,
    .Init = sfxInit,
    .Shutdown = sfxShutdown,
    .GetSfxLumpNum = sfxGetLumpNum,
    .Update = sfxUpdate,
    .UpdateSoundParams = sfxUpdateParams,
    .StartSound = sfxStart,
    .StopSound = sfxStop,
    .SoundIsPlaying = sfxIsPlaying,
    .CacheSounds = null,
};
