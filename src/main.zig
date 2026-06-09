const std = @import("std");
const d = @import("doom_c");

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    d.doomgeneric_Create(@intCast(args.len), @constCast(@ptrCast(args.ptr)));
    while (true) {
        d.doomgeneric_Tick();
    }
}
