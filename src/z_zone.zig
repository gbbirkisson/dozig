const std = @import("std");
const cstdio = @cImport({
    @cInclude("stdio.h");
});

pub export fn Z_Init() void
{
    std.debug.panic("Unimplemented Z_Init", .{});
}

pub export fn Z_Malloc(size: c_int, tag: c_int, ptr: *anyopaque) *anyopaque
{
    std.debug.panic("Unimplemented Z_Malloc({}, {}, {})", .{size, tag, ptr});
}

pub export fn Z_Free(ptr: *anyopaque) void
{
    std.debug.panic("Unimplemented Z_Free({})", .{ptr});
}

pub export fn Z_FreeTags(size: c_int, tag: c_int) void
{
    std.debug.panic("Unimplemented Z_FreeTags({}, {})", .{size, tag});
}

pub export fn Z_DumpHeap(size: c_int, tag: c_int) void
{
    std.debug.panic("Unimplemented Z_DumpHeap({}, {})", .{size, tag});
}

pub export fn Z_FileDumpHeap(file: *cstdio.FILE) void
{
    std.debug.panic("Unimplemented Z_FileDumpHeap({})", .{file});
}

pub export fn Z_CheckHeap() void
{
    std.debug.panic("Unimplemented Z_CheckHeap()", .{});
}

pub export fn Z_ChangeTag2(ptr: *anyopaque, tag: c_int, file: *c_char, line: c_int) void
{
    std.debug.panic("Unimplemented Z_ChangeTag2({}, {}, {}, {})", .{ptr, tag, file, line});
}

pub export fn Z_ChangeUser(ptr: *anyopaque, user: **anyopaque) void
{
    std.debug.panic("Unimplemented Z_ChangeTag2({}, {})", .{ptr, user});
}

pub export fn Z_FreeMemory() c_int
{
    std.debug.panic("Unimplemented Z_FreeMemory()", .{});
}

pub export fn Z_ZoneSize() c_uint
{
    std.debug.panic("Unimplemented Z_ZoneSize()", .{});
}
