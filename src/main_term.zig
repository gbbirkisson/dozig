//! Terminal demo player: plays Doom's attract loop as ANSI half-block art on stdout.
//! Usage: dozig -iwad doom1.wad [-cols 160]

const std = @import("std");
const dozig = @import("dozig");

const session_begin = "\x1b[2J\x1b[?25l";
const session_end = "\x1b[0m\x1b[?25h";
const default_cols = 160;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var cols: u32 = default_cols;
    var args: std.ArrayList([*:0]const u8) = .empty;
    defer args.deinit(gpa);
    const argv = init.minimal.args.vector;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(argv[i]), "-cols") and i + 1 < argv.len) {
            i += 1;
            cols = try std.fmt.parseInt(u32, std.mem.span(argv[i]), 10);
        } else {
            try args.append(gpa, argv[i]);
        }
    }

    // Validates cols before touching the terminal; one frame fits the buffer, one write per frame.
    const buf = try gpa.alloc(u8, try dozig.ansi.maxLen(cols));
    defer gpa.free(buf);

    var engine = try dozig.Engine.init(gpa, args.items);
    defer engine.deinit();

    var stdout = std.Io.File.stdout().writerStreaming(io, buf);
    const w = &stdout.interface;
    try w.writeAll(session_begin);
    defer {
        w.writeAll(session_end) catch {};
        w.flush() catch {};
    }

    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const frame = try engine.next();
        const due = start.addDuration(.fromMilliseconds(@intCast(frame.time_ms)));
        const wait = std.Io.Timestamp.now(io, .awake).durationTo(due);
        if (wait.nanoseconds > 0) try io.sleep(wait, .awake);
        try dozig.ansi.encode(frame, cols, w);
        try w.flush();
    }
}
