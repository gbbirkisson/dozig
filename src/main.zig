const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const config = @import("config");
const doom = @import("interop");

// Our SDL wrappers
const sdl_input = @import("sdl_input.zig");
const convertToDoomKey = sdl_input.convertToDoomKey;
const runApp = @import("sdl.zig").runApp;
const errify = @import("sdl.zig").errify;

// Force-link the audio modules and any Zig engine ports (registry is generated
// by build.zig; empty when nothing is ported).
comptime {
    _ = @import("sdl_sound.zig");
    _ = @import("sdl_music.zig");
    _ = @import("engine_registry");
}

// Route std.log through SDL. Besides integrating with SDL's logging (browser console on
// Emscripten), this avoids std's default log handler, whose Io.Threaded implementation fails to
// compile for wasm32-emscripten on Zig 0.16.0.
pub const std_options: std.Options = .{ .logFn = sdlLog };

fn sdlLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, comptime level.asText() ++ ": " ++ format, args, 0) catch return;
    sdl.SDL_Log("%s", msg.ptr);
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
var s_KeyQueue: [KEYQUEUE_SIZE]u16 = @splat(0);
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
    // -Dfullscreen: borderless fullscreen-desktop, native only (the wasm
    // "window" is the canvas; browser fullscreen is a different mechanism).
    const fullscreen = comptime config.DOZIG_FULLSCREEN and builtin.os.tag != .emscripten;
    const flags: sdl.SDL_WindowFlags = if (fullscreen) sdl.SDL_WINDOW_FULLSCREEN else 0;
    window = try errify(sdl.SDL_CreateWindow("DOOM", RESX, RESY, flags));
    renderer = try errify(sdl.SDL_CreateRenderer(window, null));
    if (fullscreen) {
        // Keep the game's 16:10 geometry on any display: scale to fit with
        // black bars; the texture keeps rendering to a logical RESXxRESY.
        try errify(sdl.SDL_SetRenderLogicalPresentation(renderer, RESX, RESY, sdl.SDL_LOGICAL_PRESENTATION_LETTERBOX));
    }
    texture = try errify(sdl.SDL_CreateTexture(
        renderer,
        sdl.SDL_PIXELFORMAT_XRGB8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        RESX,
        RESY,
    ));
    sdl_input.initMouse(window);
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
    // After M_LoadDefaults (inside doomgeneric_Create) so user config wins.
    sdl_input.bindMouseButtons();
    return sdl.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !sdl.SDL_AppResult {
    sdl_input.updateMouseGrab(window);
    sdl_input.postMouseEvent();
    doom.doomgeneric_Tick();
    return sdl.SDL_APP_CONTINUE;
}

fn sdlAppEvent(event: *sdl.SDL_Event) !sdl.SDL_AppResult {
    switch (event.type) {
        sdl.SDL_EVENT_QUIT => return sdl.SDL_APP_SUCCESS,
        sdl.SDL_EVENT_KEY_DOWN => addKeyToQueue(true, event.key.key),
        sdl.SDL_EVENT_KEY_UP => addKeyToQueue(false, event.key.key),
        sdl.SDL_EVENT_MOUSE_MOTION,
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN,
        sdl.SDL_EVENT_MOUSE_BUTTON_UP,
        sdl.SDL_EVENT_MOUSE_WHEEL,
        => sdl_input.handleMouseEvent(event),
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
