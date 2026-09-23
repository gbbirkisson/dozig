//! One rendered Doom frame, shared by the headless backend and the ANSI encoder.

pub const width = 320;
pub const height = 200;

/// XRGB8888 (0x00RRGGBB), row-major.
pub const Pixels = [height][width]u32;

pub const Frame = struct {
    /// Virtual engine time since init. Monotonic; advances only while frames are pulled.
    time_ms: u64,
    /// Borrowed until the next `Engine.next()`.
    pixels: *const Pixels,
};
