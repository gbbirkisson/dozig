//! SDL3 input -> Doom: keycode mapping plus mouse handling (capture,
//! accumulation, ev_mouse posting via D_PostEvent).

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const doom = @import("doom.zig");
const config = @import("config");

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

// Mouse state: accumulated relative motion + current button mask. Posted to
// the engine as ONE ev_mouse per tick — g_game.c:830 overwrites mousex per
// event rather than accumulating, so per-SDL-event posting drops motion.
/// Raw SDL pixel deltas read far lower than the DOS mouse counts the
/// engine's sensitivity math expects, so scale them up. Baseline comes from
/// the build (-Dmouse_scale=, default 3.5); the in-game slider then adjusts
/// around it (x0.5 .. x1.4).
const MOUSE_SCALE = config.DOZIG_MOUSE_SCALE;

var mouse_dx: f32 = 0;
var mouse_buttons: c_int = 0;
var last_posted_buttons: c_int = 0;
var mouse_grabbed = false;

// Phantom button bits for the mouse wheel: the engine cycles weapons on
// presses of buttons bound to mousebnextweapon/mousebprevweapon
// (g_game.c SetMouseButtons). Reporting wheel ticks as buttons 3/4 is the
// same trick chocolate-doom uses; bits are impulses, cleared after posting.
const WHEEL_UP_BIT: c_int = 1 << 3;
const WHEEL_DOWN_BIT: c_int = 1 << 4;
var wheel_bits: c_int = 0;

/// Our mouse-button defaults, applied unless the user's config already
/// bound them. Must run AFTER doomgeneric_Create (so M_LoadDefaults has
/// run and an explicit user config wins).
pub fn bindMouseButtons() void {
    if (doom.mousebnextweapon == -1 and doom.mousebprevweapon == -1) {
        doom.mousebnextweapon = 3; // wheel up
        doom.mousebprevweapon = 4; // wheel down
    }
    // Right button = use (modern convention) instead of vanilla's strafe
    // modifier.
    if (doom.mousebuse == -1) {
        doom.mousebuse = 1;
        doom.mousebstrafe = -1;
    }
}

/// One-time mouse setup. Wasm only: pointer lock for the whole session
/// (granted at first click) — toggling it dynamically would demand a canvas
/// click after every menu visit, so it stays on. Native capture is handled
/// dynamically by updateMouseGrab.
pub fn initMouse(window: ?*sdl.SDL_Window) void {
    if (comptime builtin.os.tag != .emscripten) return;
    if (!sdl.SDL_SetWindowRelativeMouseMode(window, true)) {
        std.log.warn("relative mouse mode failed: {s}", .{sdl.SDL_GetError()});
    }
}

/// Handle an SDL mouse event (motion or button); other events are ignored.
pub fn handleMouseEvent(event: *sdl.SDL_Event) void {
    switch (event.type) {
        sdl.SDL_EVENT_MOUSE_MOTION => mouse_dx += event.motion.xrel * MOUSE_SCALE,
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            // SDL numbers buttons 1=left/2=middle/3=right; Doom wants a
            // bitfield with bit 0 left, bit 1 right, bit 2 middle.
            const bit: c_int = switch (event.button.button) {
                sdl.SDL_BUTTON_LEFT => 1 << 0,
                sdl.SDL_BUTTON_RIGHT => 1 << 1,
                sdl.SDL_BUTTON_MIDDLE => 1 << 2,
                else => 0,
            };
            if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                mouse_buttons |= bit;
                if (comptime builtin.os.tag == .emscripten) {
                    if (!was_pointer_locked) {
                        // Re-capture on click. SDL re-requests the lock
                        // itself, but under asyncify that runs outside the
                        // user-gesture context and the browser denies it;
                        // defer=true parks the request and fires it inside
                        // the next real user event handler instead.
                        _ = emscripten_request_pointerlock("#canvas", true);
                    }
                }
            } else {
                mouse_buttons &= ~bit;
            }
        },
        sdl.SDL_EVENT_MOUSE_WHEEL => {
            if (event.wheel.y > 0) wheel_bits |= WHEEL_UP_BIT;
            if (event.wheel.y < 0) wheel_bits |= WHEEL_DOWN_BIT;
        },
        else => {},
    }
}

/// Post the accumulated mouse state as a single ev_mouse, only when there
/// is motion or a button change (held buttons need no re-post; the engine
/// keeps the state from the last event). Call once per tick.
pub fn postMouseEvent() void {
    const dx: c_int = @intFromFloat(@round(mouse_dx));
    const buttons = mouse_buttons | wheel_bits;
    if (dx == 0 and buttons == last_posted_buttons) return;
    var ev: doom.Event = .{
        .type = doom.ev_mouse,
        .data1 = buttons,
        .data2 = dx, // positive = turn right (matches i_input.c:331 reference)
        .data3 = 0, // vertical movement intentionally ignored ("novert")
    };
    doom.D_PostEvent(&ev);
    mouse_dx = 0;
    // Wheel bits are impulses: the next post (buttons reverting to
    // mouse_buttons) releases them, re-arming the press detection.
    wheel_bits = 0;
    last_posted_buttons = buttons;
}

// emscripten/html5.h pointer-lock status (wasm only; unreferenced — and
// therefore not linked — on native).
const EmscriptenPointerlockChangeEvent = extern struct {
    is_active: bool,
    node_name: [128]u8,
    id: [128]u8,
};
extern fn emscripten_get_pointerlock_status(status: *EmscriptenPointerlockChangeEvent) c_int;
extern fn emscripten_request_pointerlock(target: [*:0]const u8, defer_until_in_event_handler: bool) c_int;

var was_pointer_locked = false;

/// Post a synthetic key press+release straight to the engine's event queue.
fn postKey(key: u8) void {
    var down: doom.Event = .{ .type = doom.ev_keydown, .data1 = key };
    doom.D_PostEvent(&down);
    var up: doom.Event = .{ .type = doom.ev_keyup, .data1 = key };
    doom.D_PostEvent(&up);
}

/// Native: capture only while actually playing — cursor free in menus,
/// demos, and pause. Wasm: browsers exit pointer lock on Esc and swallow
/// the keypress (and SDL re-locks on the next click), which would make the
/// menu unreachable — so treat a lock loss as the Esc it was and synthesize
/// the keypress. Call once per tick.
pub fn updateMouseGrab(window: ?*sdl.SDL_Window) void {
    if (comptime builtin.os.tag == .emscripten) {
        var status: EmscriptenPointerlockChangeEvent = undefined;
        if (emscripten_get_pointerlock_status(&status) == 0) {
            const locked = status.is_active;
            if (was_pointer_locked and !locked) postKey(doom.keys.KEY_ESCAPE);
            was_pointer_locked = locked;
        }
        return;
    }
    const want = doom.gamestate == doom.GS_LEVEL and
        doom.demoplayback == doom.FALSE and
        doom.menuactive == doom.FALSE and
        doom.paused == doom.FALSE;
    if (want == mouse_grabbed) return;
    mouse_grabbed = want;
    if (!sdl.SDL_SetWindowRelativeMouseMode(window, want)) {
        std.log.warn("mouse grab toggle failed: {s}", .{sdl.SDL_GetError()});
    }
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

pub fn convertToDoomKey(key: sdl.SDL_Keycode) u8 {
    return switch (key) {
        // Extra
        sdl.SDLK_W => doom.keys.KEY_UPARROW,
        sdl.SDLK_S => doom.keys.KEY_DOWNARROW,
        sdl.SDLK_A => doom.keys.KEY_STRAFE_L,
        sdl.SDLK_D => doom.keys.KEY_STRAFE_R,
        sdl.SDLK_E => doom.keys.KEY_USE,

        // Original
        sdl.SDLK_RETURN => doom.keys.KEY_ENTER,
        sdl.SDLK_ESCAPE => doom.keys.KEY_ESCAPE,
        sdl.SDLK_LEFT => doom.keys.KEY_LEFTARROW,
        sdl.SDLK_RIGHT => doom.keys.KEY_RIGHTARROW,
        sdl.SDLK_UP => doom.keys.KEY_UPARROW,
        sdl.SDLK_DOWN => doom.keys.KEY_DOWNARROW,
        sdl.SDLK_LCTRL, sdl.SDLK_RCTRL => doom.keys.KEY_FIRE,
        sdl.SDLK_SPACE => doom.keys.KEY_USE,
        sdl.SDLK_LSHIFT, sdl.SDLK_RSHIFT => doom.keys.KEY_RSHIFT,
        sdl.SDLK_LALT, sdl.SDLK_RALT => doom.keys.KEY_LALT,
        sdl.SDLK_F2 => doom.keys.KEY_F2,
        sdl.SDLK_F3 => doom.keys.KEY_F3,
        sdl.SDLK_F4 => doom.keys.KEY_F4,
        sdl.SDLK_F5 => doom.keys.KEY_F5,
        sdl.SDLK_F6 => doom.keys.KEY_F6,
        sdl.SDLK_F7 => doom.keys.KEY_F7,
        sdl.SDLK_F8 => doom.keys.KEY_F8,
        sdl.SDLK_F9 => doom.keys.KEY_F9,
        sdl.SDLK_F10 => doom.keys.KEY_F10,
        sdl.SDLK_F11 => doom.keys.KEY_F11,
        sdl.SDLK_EQUALS, sdl.SDLK_PLUS => doom.keys.KEY_EQUALS,
        sdl.SDLK_MINUS => doom.keys.KEY_MINUS,
        else => blk: {
            // Match the original tolower(key) default for letter keys.
            var k = key;
            if (k >= 'A' and k <= 'Z') k += ('a' - 'A');
            break :blk @truncate(k);
        },
    };
}
