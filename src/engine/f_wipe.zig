//! Screen-melt transition (port of doom/f_wipe.c).
//!
//! ELI5: at a level change Doom freezes the old screen and the new screen, then
//! "melts" — each vertical strip of the new screen drips down over the old one,
//! each strip starting at a slightly different, RNG-wobbled time, until the new
//! screen fully covers the old. Purely visual.

const std = @import("std");
const builtin = @import("builtin");
const rng = @import("m_random");

// ----- Constants -----

const SCREENWIDTH = 320; // mirrors doom/i_video.h (the engine's paletted framebuffer)
const SCREENHEIGHT = 200;
const N = SCREENWIDTH * SCREENHEIGHT; // 64000 bytes per screen

// ----- Idiomatic Zig API -----

// Per-column drip offset (in pixel rows). Negative = not started yet.
var melt_y: [SCREENWIDTH]i32 = undefined;

/// Seed the per-column drip offsets from the RNG — a random walk that staggers
/// when each column starts and how far apart neighbours are. Replicates vanilla's
/// exact 320-draw loop (so the melt pattern and RNG consumption match).
/// C engine equivalent: wipe_initMelt's column setup (doom/f_wipe.c).
fn initColumns() void {
    melt_y[0] = -@as(i32, rng.misc() % 16);
    var i: usize = 1;
    while (i < SCREENWIDTH) : (i += 1) {
        const r = @as(i32, rng.misc() % 3) - 1; // -1, 0, or +1
        melt_y[i] = melt_y[i - 1] + r;
        if (melt_y[i] > 0) {
            melt_y[i] = 0;
        } else if (melt_y[i] == -16) {
            melt_y[i] = -15;
        }
    }
}

var active: bool = false;
var scr_start: [N]u8 align(2) = undefined; // frozen "from" screen (transposed to col-major during a wipe)
var scr_end: [N]u8 align(2) = undefined; // frozen "to" screen (likewise)
var xform_tmp: [SCREENWIDTH / 2 * SCREENHEIGHT]i16 = undefined; // transpose scratch

extern var I_VideoBuffer: [*c]u8; // the live paletted framebuffer (doom/i_video.c)

/// Transpose a 160x200 short image to column-major, in place — makes the column
/// scroll below a straight walk down memory.
/// C engine equivalent: wipe_shittyColMajorXform (doom/f_wipe.c).
fn transpose(buf: *align(2) [N]u8) void {
    const a = std.mem.bytesAsSlice(i16, buf[0..]); // 32000 shorts
    const w = SCREENWIDTH / 2; // 160 short-columns
    const h = SCREENHEIGHT; // 200 rows
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) xform_tmp[x * h + y] = a[y * w + x];
    }
    @memcpy(a, xform_tmp[0 .. w * h]);
}

/// Advance the melt by `ticks` steps, writing into `target` (row-major shorts).
/// Each column drips the end screen down from the top and pushes the start
/// screen below it. Returns true when every column is fully covered.
/// C engine equivalent: wipe_doMelt (doom/f_wipe.c).
fn doMelt(target: []align(2) u8, ticks_in: i32) bool {
    const w = SCREENWIDTH / 2;
    const h: i32 = SCREENHEIGHT;
    const end_s = std.mem.bytesAsSlice(i16, scr_end[0..]); // col-major
    const start_s = std.mem.bytesAsSlice(i16, scr_start[0..]); // col-major
    const dst = std.mem.bytesAsSlice(i16, target); // row-major
    var done = true;
    var ticks = ticks_in;
    while (ticks > 0) : (ticks -= 1) {
        var i: usize = 0;
        while (i < w) : (i += 1) {
            if (melt_y[i] < 0) {
                melt_y[i] += 1;
                done = false;
            } else if (melt_y[i] < h) {
                var dy: i32 = if (melt_y[i] < 16) melt_y[i] + 1 else 8;
                if (melt_y[i] + dy >= h) dy = h - melt_y[i];
                // drip `dy` rows of the end screen down column i
                var se: usize = i * @as(usize, @intCast(h)) + @as(usize, @intCast(melt_y[i]));
                var d: usize = @as(usize, @intCast(melt_y[i])) * w + i;
                var j: i32 = dy;
                while (j > 0) : (j -= 1) {
                    dst[d] = end_s[se];
                    se += 1;
                    d += w;
                }
                melt_y[i] += dy;
                // fill the rest of column i with the start screen (scrolled down)
                var ss: usize = i * @as(usize, @intCast(h));
                d = @as(usize, @intCast(melt_y[i])) * w + i;
                var k: i32 = h - melt_y[i];
                while (k > 0) : (k -= 1) {
                    dst[d] = start_s[ss];
                    ss += 1;
                    d += w;
                }
                done = false;
            }
        }
    }
    return done;
}

/// Advance the wipe into `target`; returns true when finished. First call
/// captures the "from" screen into `target`, transposes both screens, and seeds
/// the columns. C engine equivalent: wipe_ScreenWipe's melt path (doom/f_wipe.c).
pub fn tick(target: []align(2) u8, ticks: i32) bool {
    if (!active) {
        active = true;
        @memcpy(target[0..N], scr_start[0..N]);
        transpose(&scr_start);
        transpose(&scr_end);
        initColumns();
    }
    const done = doMelt(target, ticks);
    if (done) active = false;
    return done;
}

/// Freeze the current screen as the melt's "from" frame.
/// C engine equivalent: wipe_StartScreen (doom/f_wipe.c); inlines I_ReadScreen.
fn captureStart() void {
    @memcpy(scr_start[0..N], I_VideoBuffer[0..N]);
}

/// Freeze the target screen as the "to" frame, then put the start screen back on
/// display so it's what's shown as the melt begins.
/// C engine equivalent: wipe_EndScreen (doom/f_wipe.c); inlines I_ReadScreen + V_DrawBlock.
fn captureEnd() void {
    @memcpy(scr_end[0..N], I_VideoBuffer[0..N]);
    @memcpy(I_VideoBuffer[0..N], scr_start[0..N]); // restore start screen for display
}

// ----- C-ABI bridge -----
// Exported only in non-test builds: these reference the `I_VideoBuffer` extern,
// which the C engine provides but a `zig build test` binary does not. Guarding
// them keeps the test binary linkable (the testable core touches no externs).

fn wipeStartScreen(x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) c_int {
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    captureStart();
    return 0;
}
fn wipeEndScreen(x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) c_int {
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    captureEnd();
    return 0;
}
fn wipeScreenWipe(wipeno: c_int, x: c_int, y: c_int, width: c_int, height: c_int, ticks: c_int) callconv(.c) c_int {
    _ = wipeno; // always wipe_Melt
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    return @intFromBool(tick(@alignCast(I_VideoBuffer[0..N]), ticks));
}

comptime {
    if (!builtin.is_test) {
        @export(&wipeStartScreen, .{ .name = "wipe_StartScreen" });
        @export(&wipeEndScreen, .{ .name = "wipe_EndScreen" });
        @export(&wipeScreenWipe, .{ .name = "wipe_ScreenWipe" });
    }
}

// ----- Tests -----

test "initColumns matches vanilla's RNG-seeded melt walk" {
    rng.clear();
    initColumns();
    // Hand-derived from m_random.rndtable after clear(): misc() yields 8,109,220,222,241,149,107,75,...
    const expected = [_]i32{ -8, -8, -8, -9, -9, -8, -7, -8 };
    for (expected, 0..) |v, i| try std.testing.expectEqual(v, melt_y[i]);
}

test "tick melts the end screen fully over the start screen" {
    rng.clear();
    active = false;
    // Distinguishable, non-uniform patterns so a stride/transpose bug can't hide.
    var expected_end: [N]u8 = undefined;
    for (scr_start[0..], scr_end[0..], expected_end[0..], 0..) |*a, *b, *e, i| {
        a.* = 0x11;
        b.* = @truncate(i); // gradient
        e.* = b.*; // save the ORIGINAL end screen (tick will transpose scr_end in place)
    }
    var target: [N]u8 align(2) = undefined;
    @memset(target[0..], 0);
    var guard: usize = 0;
    while (!tick(target[0..], 8)) : (guard += 1) {
        try std.testing.expect(guard < 1000); // must converge
    }
    // A fully-completed melt reproduces the original end screen, pixel-for-pixel.
    try std.testing.expect(std.mem.eql(u8, target[0..], expected_end[0..]));
}
