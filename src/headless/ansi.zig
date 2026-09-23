//! Frame to ANSI truecolor text. Each cell is an upper half block: fg = top pixel, bg = bottom.

const std = @import("std");
const frame = @import("frame.zig");
const Frame = frame.Frame;
const Pixels = frame.Pixels;

pub const Error = error{InvalidWidth};

const upper_half = "\u{2580}";
const home = "\x1b[H";
const reset = "\x1b[0m";
const newline = "\r\n";
const fg_max = "\x1b[38;2;255;255;255m";
const bg_max = "\x1b[48;2;255;255;255m";

/// Source pixels per cell side. Pixel rows pair into cells, so the scaled height must be even.
fn scale(cols: u32) Error!u32 {
    if (cols == 0 or frame.width % cols != 0) return error.InvalidWidth;
    const s = frame.width / cols;
    if (frame.height % (2 * s) != 0) return error.InvalidWidth;
    return s;
}

/// Worst-case byte count `encode` writes for `cols`.
pub fn maxLen(cols: u32) Error!usize {
    const s = try scale(cols);
    const rows = frame.height / (2 * s);
    const cell = fg_max.len + bg_max.len + upper_half.len;
    return home.len + rows * (cols * cell + reset.len) + (rows - 1) * newline.len;
}

/// Writes `f` as `cols` wide cells, cursor homed first. `cols` must be 320, 160, 80, 64, 32 or 16.
pub fn encode(f: Frame, cols: u32, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    const s: usize = try scale(cols);
    const rows = frame.height / (2 * s);
    try w.writeAll(home);
    for (0..rows) |row| {
        if (row > 0) try w.writeAll(newline);
        var fg: ?u32 = null;
        var bg: ?u32 = null;
        for (0..cols) |col| {
            const top = average(f.pixels, col * s, 2 * row * s, s);
            const bottom = average(f.pixels, col * s, (2 * row + 1) * s, s);
            if (fg == null or fg.? != top) {
                try w.print("\x1b[38;2;{d};{d};{d}m", .{ channel(top, 16), channel(top, 8), channel(top, 0) });
                fg = top;
            }
            if (bg == null or bg.? != bottom) {
                try w.print("\x1b[48;2;{d};{d};{d}m", .{ channel(bottom, 16), channel(bottom, 8), channel(bottom, 0) });
                bg = bottom;
            }
            try w.writeAll(upper_half);
        }
        try w.writeAll(reset);
    }
}

/// Mean color of the `s`x`s` block with top-left corner (`x`, `y`).
fn average(p: *const Pixels, x: usize, y: usize, s: usize) u32 {
    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;
    for (p[y..][0..s]) |line| {
        for (line[x..][0..s]) |px| {
            r += channel(px, 16);
            g += channel(px, 8);
            b += channel(px, 0);
        }
    }
    const n: u32 = @intCast(s * s);
    return (r / n) << 16 | (g / n) << 8 | b / n;
}

fn channel(px: u32, shift: u5) u8 {
    return @truncate(px >> shift);
}

// ----- Tests -----

const testing = std.testing;
const valid_cols = [_]u32{ 320, 160, 80, 64, 32, 16 };

fn filled(color: u32) !*Pixels {
    const p = try testing.allocator.create(Pixels);
    for (p) |*line| line.* = @splat(color);
    return p;
}

fn encodeAlloc(p: *const Pixels, cols: u32) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try encode(.{ .time_ms = 0, .pixels = p }, cols, &out.writer);
    return out;
}

test "solid frame: home, one fg/bg pair per row, rows joined by CRLF, no trailing newline" {
    const p = try filled(0x102030);
    defer testing.allocator.destroy(p);
    var out = try encodeAlloc(p, 16);
    defer out.deinit();

    var want: std.Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    try want.writer.writeAll("\x1b[H");
    for (0..5) |row| {
        if (row > 0) try want.writer.writeAll("\r\n");
        try want.writer.writeAll("\x1b[38;2;16;32;48m\x1b[48;2;16;32;48m");
        for (0..16) |_| try want.writer.writeAll(upper_half);
        try want.writer.writeAll("\x1b[0m");
    }
    try testing.expectEqualStrings(want.written(), out.written());
}

test "fg is the top pixel, bg the bottom, repeats are skipped" {
    const p = try testing.allocator.create(Pixels);
    defer testing.allocator.destroy(p);
    for (p, 0..) |*line, y| line.* = @splat(@as(u32, if (y % 2 == 0) 0xff0000 else 0x0000ff));
    var out = try encodeAlloc(p, 320);
    defer out.deinit();

    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[H\x1b[38;2;255;0;0m\x1b[48;2;0;0;255m"));
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, out.written(), "\x1b[38;2;"));
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, out.written(), "\x1b[48;2;"));
}

test "downscale box-averages each block" {
    const p = try testing.allocator.create(Pixels);
    defer testing.allocator.destroy(p);
    for (p, 0..) |*line, y| {
        for (line, 0..) |*px, x| px.* = if ((x + y) % 2 == 0) 0x000000 else 0xfefefe;
    }
    var out = try encodeAlloc(p, 160);
    defer out.deinit();

    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[H\x1b[38;2;127;127;127m\x1b[48;2;127;127;127m"));
}

test "invalid widths are rejected" {
    const p = try filled(0);
    defer testing.allocator.destroy(p);
    for ([_]u32{ 0, 1, 40, 100, 321, 640 }) |cols| {
        try testing.expectError(error.InvalidWidth, maxLen(cols));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(error.InvalidWidth, encode(.{ .time_ms = 0, .pixels = p }, cols, &out.writer));
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
}

test "worst-case noise stays within maxLen for every valid width" {
    const p = try testing.allocator.create(Pixels);
    defer testing.allocator.destroy(p);
    var prng: std.Random.DefaultPrng = .init(0);
    for (p) |*line| {
        for (line) |*px| px.* = prng.random().int(u24);
    }
    for (valid_cols) |cols| {
        var out = try encodeAlloc(p, cols);
        defer out.deinit();
        try testing.expect(out.written().len <= try maxLen(cols));
    }
}
