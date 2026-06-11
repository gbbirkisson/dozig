//! Generic SDL3 plumbing: error conversion and the app-callback entry point. Nothing in here is
//! Doom-specific — it wraps SDL's C-ABI main-callback model so callers can supply ordinary Zig
//! callbacks that return error unions.
//!
//! Error plumbing (ErrorStore, errify) ported from castholm/zig-examples/breakout (MIT).

const std = @import("std");
const sdl = @import("sdl");

var app_err: ErrorStore = .{};

/// Stashes a Zig error across the C-ABI callback boundary so it can be recovered after
/// SDL_RunApp returns.
const ErrorStore = struct {
    const status_not_stored = 0;
    const status_storing = 1;
    const status_stored = 2;

    status: sdl.SDL_AtomicInt = .{ .value = status_not_stored },
    err: anyerror = undefined,
    trace_index: usize = undefined,
    trace_addrs: [32]usize = undefined,

    fn store(es: *ErrorStore, err: anyerror) sdl.SDL_AppResult {
        if (sdl.SDL_CompareAndSwapAtomicInt(&es.status, status_not_stored, status_storing)) {
            es.err = err;
            if (@errorReturnTrace()) |src_trace| {
                es.trace_index = src_trace.index;
                const len = @min(es.trace_addrs.len, src_trace.instruction_addresses.len);
                @memcpy(es.trace_addrs[0..len], src_trace.instruction_addresses[0..len]);
            }
            _ = sdl.SDL_SetAtomicInt(&es.status, status_stored);
        }
        return sdl.SDL_APP_FAILURE;
    }

    fn load(es: *ErrorStore) ?anyerror {
        if (sdl.SDL_GetAtomicInt(&es.status) != status_stored) return null;
        if (@errorReturnTrace()) |dst_trace| {
            dst_trace.index = es.trace_index;
            const len = @min(dst_trace.instruction_addresses.len, es.trace_addrs.len);
            @memcpy(dst_trace.instruction_addresses[0..len], es.trace_addrs[0..len]);
        }
        return es.err;
    }
};

/// Converts the return value of an SDL function to an error union.
pub inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

/// Runs an SDL3 app-callback application. Wires the C-ABI shims and error plumbing around the
/// supplied Zig callbacks, then drives SDL_RunApp with the given argv. Returns the first error
/// any callback raised (if any).
///
///   appInit(argv: [][*:0]u8) !c.SDL_AppResult
///   appIterate()             !c.SDL_AppResult
///   appEvent(*c.SDL_Event)   !c.SDL_AppResult
///   appQuit()                void
pub fn runApp(
    argv: []const [*:0]const u8,
    comptime appInit: anytype,
    comptime appIterate: anytype,
    comptime appEvent: anytype,
    comptime appQuit: anytype,
) !void {
    const shims = struct {
        fn initC(appstate: ?*?*anyopaque, argc: c_int, a: ?[*:null]?[*:0]u8) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            return appInit(@as([][*:0]u8, @ptrCast(a.?[0..@intCast(argc)]))) catch |err| app_err.store(err);
        }
        fn iterateC(appstate: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            return appIterate() catch |err| app_err.store(err);
        }
        fn eventC(appstate: ?*anyopaque, event: ?*sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            return appEvent(event.?) catch |err| app_err.store(err);
        }
        fn quitC(appstate: ?*anyopaque, result: sdl.SDL_AppResult) callconv(.c) void {
            _ = appstate;
            _ = result;
            appQuit();
        }
        fn mainC(argc: c_int, a: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            return sdl.SDL_EnterAppMainCallbacks(argc, @ptrCast(a), initC, iterateC, eventC, quitC);
        }
    };

    _ = sdl.SDL_RunApp(@intCast(argv.len), @ptrCast(@constCast(argv.ptr)), shims.mainC, null);
    if (app_err.load()) |err| return err;
}
