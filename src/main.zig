const std = @import("std");
const sdl = @import("sdl");
const config = @import("config");
const doom = @import("doom.zig");

// Our SDL wrappers
const convertToDoomKey = @import("sdl_input.zig").convertToDoomKey;
const runApp = @import("sdl.zig").runApp;
const errify = @import("sdl.zig").errify;

// Force-link the audio modules
comptime {
    _ = @import("sdl_sound.zig");
    _ = @import("sdl_music.zig");
}

// Screen dimensjons
const RESX: c_int = @intCast(config.DOOMGENERIC_RESX);
const RESY: c_int = @intCast(config.DOOMGENERIC_RESY);

// SDL state
var window: ?*sdl.SDL_Window = null;
var renderer: ?*sdl.SDL_Renderer = null;
var texture: ?*sdl.SDL_Texture = null;

// Input ring-buffer
const KEYQUEUE_SIZE = 16;
var s_KeyQueue: [KEYQUEUE_SIZE]u16 = [_]u16{0} ** KEYQUEUE_SIZE;
var s_KeyQueueWriteIndex: usize = 0;
var s_KeyQueueReadIndex: usize = 0;

// Input translation
fn addKeyToQueue(pressed: bool, keycode: sdl.SDL_Keycode) void {
    const key = convertToDoomKey(keycode);
    const key_data: u16 = (@as(u16, @intFromBool(pressed)) << 8) | key;
    s_KeyQueue[s_KeyQueueWriteIndex] = key_data;
    s_KeyQueueWriteIndex = (s_KeyQueueWriteIndex + 1) % KEYQUEUE_SIZE;
}

// ---------------------------------------------------------------------------
// The 6 DG_* platform functions the engine calls INTO (C -> Zig).
// ---------------------------------------------------------------------------

export fn DG_Init() void {
    dgInit() catch {
        std.log.err("DG_Init failed: {s}", .{sdl.SDL_GetError()});
        std.process.exit(1);
    };
}

fn dgInit() !void {
    try errify(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    window = try errify(sdl.SDL_CreateWindow("DOOM", RESX, RESY, 0));
    renderer = try errify(sdl.SDL_CreateRenderer(window, null));
    texture = try errify(sdl.SDL_CreateTexture(
        renderer,
        sdl.SDL_PIXELFORMAT_XRGB8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        RESX,
        RESY,
    ));
}

export fn DG_DrawFrame() void {
    dgDrawFrame() catch {
        std.log.err("DG_DrawFrame failed: {s}", .{sdl.SDL_GetError()});
    };
}

fn dgDrawFrame() !void {
    try errify(sdl.SDL_UpdateTexture(texture, null, @ptrCast(doom.DG_ScreenBuffer), RESX * @as(c_int, @sizeOf(u32))));
    try errify(sdl.SDL_RenderClear(renderer));
    try errify(sdl.SDL_RenderTexture(renderer, texture, null, null));
    try errify(sdl.SDL_RenderPresent(renderer));
}

export fn DG_SleepMs(ms: u32) void {
    sdl.SDL_Delay(ms);
}

export fn DG_GetTicksMs() u32 {
    return @truncate(sdl.SDL_GetTicks());
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
        _ = sdl.SDL_SetWindowTitle(w, title);
    }
}

// ---------------------------------------------------------------------------
// SDL3 app callbacks (drive the doomgeneric loop).
// ---------------------------------------------------------------------------

fn sdlAppInit(argv: [][*:0]u8) !sdl.SDL_AppResult {
    // Runs DG_Init (window/renderer/texture) + D_DoomMain (loads WAD, frame 1).
    doom.doomgeneric_Create(@intCast(argv.len), @ptrCast(argv.ptr));
    return sdl.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !sdl.SDL_AppResult {
    doom.doomgeneric_Tick();
    return sdl.SDL_APP_CONTINUE;
}

fn sdlAppEvent(event: *sdl.SDL_Event) !sdl.SDL_AppResult {
    switch (event.type) {
        sdl.SDL_EVENT_QUIT => return sdl.SDL_APP_SUCCESS,
        sdl.SDL_EVENT_KEY_DOWN => addKeyToQueue(true, event.key.key),
        sdl.SDL_EVENT_KEY_UP => addKeyToQueue(false, event.key.key),
        else => {},
    }
    return sdl.SDL_APP_CONTINUE;
}

fn sdlAppQuit() void {
    if (texture) |t| sdl.SDL_DestroyTexture(t);
    if (renderer) |r| sdl.SDL_DestroyRenderer(r);
    if (window) |w| sdl.SDL_DestroyWindow(w);
}

pub fn main(init: std.process.Init.Minimal) void {
    // Pass the real argv so Doom sees -iwad / -warp / etc.
    runApp(init.args.vector, sdlAppInit, sdlAppIterate, sdlAppEvent, sdlAppQuit) catch |err| {
        std.log.err("app error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
