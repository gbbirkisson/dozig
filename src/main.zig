const std = @import("std");
const c = @import("c");
const sdl = @import("sdl.zig");
const sdl_input = @import("sdl_input.zig");
const config = @import("config");

// ---------------------------------------------------------------------------
// doomgeneric C engine symbols we call INTO (Zig -> C).
// Hand-declared instead of translate-c; only four things are needed.
// ---------------------------------------------------------------------------
extern fn doomgeneric_Create(argc: c_int, argv: [*c][*c]u8) void;
extern fn doomgeneric_Tick() void;
extern var DG_ScreenBuffer: [*c]u32; // pixel_t* (uint32_t*), filled by the engine

const RESX: c_int = @intCast(config.resx);
const RESY: c_int = @intCast(config.resy);

// ---------------------------------------------------------------------------
// SDL state + input ring buffer (single-threaded: all SDL callbacks and the
// DG_* functions run on the main thread).
// ---------------------------------------------------------------------------
var window: ?*c.SDL_Window = null;
var renderer: ?*c.SDL_Renderer = null;
var texture: ?*c.SDL_Texture = null;

const KEYQUEUE_SIZE = 16;
var s_KeyQueue: [KEYQUEUE_SIZE]u16 = [_]u16{0} ** KEYQUEUE_SIZE;
var s_KeyQueueWriteIndex: usize = 0;
var s_KeyQueueReadIndex: usize = 0;

const errify = sdl.errify;

// ---------------------------------------------------------------------------
// Input translation
// ---------------------------------------------------------------------------
fn addKeyToQueue(pressed: bool, keycode: c.SDL_Keycode) void {
    const key = sdl_input.convertToDoomKey(keycode);
    const key_data: u16 = (@as(u16, @intFromBool(pressed)) << 8) | key;
    s_KeyQueue[s_KeyQueueWriteIndex] = key_data;
    s_KeyQueueWriteIndex = (s_KeyQueueWriteIndex + 1) % KEYQUEUE_SIZE;
}

// ---------------------------------------------------------------------------
// The 6 DG_* platform functions the engine calls INTO (C -> Zig).
// ---------------------------------------------------------------------------
export fn DG_Init() void {
    dgInit() catch {
        std.log.err("DG_Init failed: {s}", .{c.SDL_GetError()});
        std.process.exit(1);
    };
}

fn dgInit() !void {
    try errify(c.SDL_Init(c.SDL_INIT_VIDEO));
    window = try errify(c.SDL_CreateWindow("DOOM", RESX, RESY, 0));
    renderer = try errify(c.SDL_CreateRenderer(window, null));
    texture = try errify(c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_XRGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        RESX,
        RESY,
    ));
}

export fn DG_DrawFrame() void {
    dgDrawFrame() catch {
        std.log.err("DG_DrawFrame failed: {s}", .{c.SDL_GetError()});
    };
}

fn dgDrawFrame() !void {
    try errify(c.SDL_UpdateTexture(texture, null, @ptrCast(DG_ScreenBuffer), RESX * @as(c_int, @sizeOf(u32))));
    try errify(c.SDL_RenderClear(renderer));
    try errify(c.SDL_RenderTexture(renderer, texture, null, null));
    try errify(c.SDL_RenderPresent(renderer));
}

export fn DG_SleepMs(ms: u32) void {
    c.SDL_Delay(ms);
}

export fn DG_GetTicksMs() u32 {
    return @truncate(c.SDL_GetTicks());
}

export fn DG_GetKey(pressed: [*c]c_int, doom_key: [*c]u8) c_int {
    if (s_KeyQueueReadIndex == s_KeyQueueWriteIndex) return 0; // empty
    const key_data = s_KeyQueue[s_KeyQueueReadIndex];
    s_KeyQueueReadIndex = (s_KeyQueueReadIndex + 1) % KEYQUEUE_SIZE;
    pressed.* = @intCast(key_data >> 8);
    doom_key.* = @truncate(key_data);
    return 1;
}

export fn DG_SetWindowTitle(title: [*c]const u8) void {
    if (window) |w| {
        _ = c.SDL_SetWindowTitle(w, title);
    }
}

// ---------------------------------------------------------------------------
// SDL3 app callbacks (drive the doomgeneric loop).
// ---------------------------------------------------------------------------
fn sdlAppInit(argv: [][*:0]u8) !c.SDL_AppResult {
    // Runs DG_Init (window/renderer/texture) + D_DoomMain (loads WAD, frame 1).
    doomgeneric_Create(@intCast(argv.len), @ptrCast(argv.ptr));
    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !c.SDL_AppResult {
    doomgeneric_Tick();
    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(event: *c.SDL_Event) !c.SDL_AppResult {
    switch (event.type) {
        c.SDL_EVENT_QUIT => return c.SDL_APP_SUCCESS,
        c.SDL_EVENT_KEY_DOWN => addKeyToQueue(true, event.key.key),
        c.SDL_EVENT_KEY_UP => addKeyToQueue(false, event.key.key),
        else => {},
    }
    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit() void {
    if (texture) |t| c.SDL_DestroyTexture(t);
    if (renderer) |r| c.SDL_DestroyRenderer(r);
    if (window) |w| c.SDL_DestroyWindow(w);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init.Minimal) void {
    // Pass the real argv so Doom sees -iwad / -warp / etc.
    sdl.runApp(init.args.vector, sdlAppInit, sdlAppIterate, sdlAppEvent, sdlAppQuit) catch |err| {
        std.log.err("app error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
