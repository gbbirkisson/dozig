//! Headless Doom as a library: runs the attract loop and yields timestamped frames.
//! One engine per process (the engine is C globals).

const std = @import("std");
const frame = @import("frame.zig");
const headless = @import("headless.zig");

comptime {
    _ = headless;
    _ = @import("engine_registry");
}

pub const ansi = @import("ansi.zig");
pub const Frame = frame.Frame;
pub const Pixels = frame.Pixels;

pub const Engine = struct {
    /// Boots the engine with Doom command-line `args`, argv[0] first (e.g. `-iwad doom1.wad`).
    /// A second call returns error.AlreadyInitialized. `args` strings must outlive the engine.
    pub fn init(gpa: std.mem.Allocator, args: []const [*:0]const u8) headless.StartError!Engine {
        try headless.start(gpa, args);
        return .{};
    }

    /// Next frame. Never sleeps: pace playback by `Frame.time_ms`.
    pub fn next(_: *Engine) headless.NextError!Frame {
        return headless.next();
    }

    /// Frees the frame queue. Later `next()` calls return error.Stopped; the engine cannot run
    /// again in this process.
    pub fn deinit(_: *Engine) void {
        headless.stop();
    }
};
