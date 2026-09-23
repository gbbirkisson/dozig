//! Headless doomgeneric backend. A virtual clock that only advances when the engine sleeps,
//! frames captured into a queue, no input, no sound.

const std = @import("std");
const interop = @import("interop");
const frame = @import("frame.zig");

const Slot = struct {
    time_ms: u64,
    pixels: frame.Pixels,
};

var started = false;
var stopped = false;
var allocator: std.mem.Allocator = undefined;
var queue: std.ArrayList(Slot) = .empty;
var head: usize = 0;
// DG_DrawFrame can't return errors; next() reports them.
var out_of_memory = false;
var clock_ms: u64 = 0;

pub const StartError = error{ AlreadyInitialized, OutOfMemory };
pub const NextError = error{ OutOfMemory, Stopped };

/// Boots the engine. Once per process. `args` strings must outlive the engine.
pub fn start(gpa: std.mem.Allocator, args: []const [*:0]const u8) StartError!void {
    if (started) return error.AlreadyInitialized;
    started = true;
    allocator = gpa;
    // doomgeneric keeps this as myargv for the process lifetime, so it is never freed.
    const argv = try std.heap.page_allocator.alloc([*c]u8, args.len + 1);
    for (args, argv[0..args.len]) |arg, *slot| slot.* = @constCast(arg);
    argv[args.len] = null;
    interop.doomgeneric_Create(@intCast(args.len), argv.ptr);
}

/// Pops the next captured frame, ticking the engine until a later frame proves it final. The
/// frame is borrowed until the next call.
pub fn next() NextError!frame.Frame {
    if (stopped) return error.Stopped;
    if (head + 1 >= queue.items.len) {
        const rest = queue.items.len - head;
        std.mem.copyForwards(Slot, queue.items[0..rest], queue.items[head..]);
        queue.shrinkRetainingCapacity(rest);
        head = 0;
        while (queue.items.len < 2 and !out_of_memory) interop.doomgeneric_Tick();
    }
    if (out_of_memory) {
        out_of_memory = false;
        return error.OutOfMemory;
    }
    const slot = &queue.items[head];
    head += 1;
    return .{ .time_ms = slot.time_ms, .pixels = &slot.pixels };
}

/// Frees the queue. Later next() calls return error.Stopped.
pub fn stop() void {
    stopped = true;
    queue.deinit(allocator);
    queue = .empty;
    head = 0;
}

// ----- doomgeneric platform functions (C -> Zig) -----

export fn DG_Init() void {}

export fn DG_DrawFrame() void {
    // TryRunTics often returns before running the tic it waited for, so D_Display redraws stale
    // state, then draws the real frame at the same time on the next tick. Keep the latter.
    const n = queue.items.len;
    const slot = if (n > head and queue.items[n - 1].time_ms == clock_ms)
        &queue.items[n - 1]
    else
        queue.addOne(allocator) catch {
            out_of_memory = true;
            return;
        };
    slot.time_ms = clock_ms;
    slot.pixels = @as(*const frame.Pixels, @ptrCast(interop.DG_ScreenBuffer)).*;
}

export fn DG_SleepMs(ms: u32) void {
    clock_ms += ms;
}

export fn DG_GetTicksMs() u32 {
    return @truncate(clock_ms);
}

export fn DG_GetKey(pressed: [*c]c_int, key: [*c]u8) c_int {
    _ = pressed;
    _ = key;
    return 0;
}

export fn DG_SetWindowTitle(title: [*c]const u8) void {
    _ = title;
}

// ----- Null sound (doom/i_sound.h) -----

// Config variables i_sound.c binds.
export var use_libsamplerate: c_int = 0;
export var libsamplerate_scale: f32 = 0.65;

// No devices: InitSfxModule never selects this module.
const no_devices = [_]interop.SndDevice{};

export var DG_sound_module: interop.SoundModule = .{
    .sound_devices = &no_devices,
    .num_sound_devices = 0,
    .Init = sfxInit,
    .Shutdown = noop,
    .GetSfxLumpNum = sfxGetLumpNum,
    .Update = noop,
    .UpdateSoundParams = sfxUpdateParams,
    .StartSound = sfxStart,
    .StopSound = sfxStop,
    .SoundIsPlaying = sfxIsPlaying,
    .CacheSounds = null,
};

// i_sound.c always installs the music module, so every call must be a safe no-op.
export var DG_music_module: interop.MusicModule = .{
    .sound_devices = &no_devices,
    .num_sound_devices = 0,
    .Init = musicInit,
    .Shutdown = noop,
    .SetMusicVolume = musicSetVolume,
    .PauseMusic = noop,
    .ResumeMusic = noop,
    .RegisterSong = musicRegisterSong,
    .UnRegisterSong = musicUnRegisterSong,
    .PlaySong = musicPlaySong,
    .StopSong = noop,
    .MusicIsPlaying = musicIsPlaying,
    .Poll = null,
};

fn noop() callconv(.c) void {}

fn sfxInit(_: interop.boolean) callconv(.c) interop.boolean {
    return interop.FALSE;
}

fn sfxGetLumpNum(_: *interop.SfxInfo) callconv(.c) c_int {
    return 0;
}

fn sfxUpdateParams(_: c_int, _: c_int, _: c_int) callconv(.c) void {}

fn sfxStart(_: *interop.SfxInfo, _: c_int, _: c_int, _: c_int) callconv(.c) c_int {
    return -1;
}

fn sfxStop(_: c_int) callconv(.c) void {}

fn sfxIsPlaying(_: c_int) callconv(.c) interop.boolean {
    return interop.FALSE;
}

fn musicInit() callconv(.c) interop.boolean {
    return interop.FALSE;
}

fn musicSetVolume(_: c_int) callconv(.c) void {}

fn musicRegisterSong(_: ?*anyopaque, _: c_int) callconv(.c) ?*anyopaque {
    return null;
}

fn musicUnRegisterSong(_: ?*anyopaque) callconv(.c) void {}

fn musicPlaySong(_: ?*anyopaque, _: interop.boolean) callconv(.c) void {}

fn musicIsPlaying() callconv(.c) interop.boolean {
    return interop.FALSE;
}
