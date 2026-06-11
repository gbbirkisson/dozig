//! Maps SDL3 keycodes to Doom key codes.

const sdl = @import("sdl");
const doom = @import("doom.zig");

pub fn convertToDoomKey(key: sdl.SDL_Keycode) u8 {
    return switch (key) {
        // Extra
        sdl.SDLK_W => doom.keys.KEY_UPARROW,
        sdl.SDLK_S => doom.keys.KEY_DOWNARROW,
        sdl.SDLK_A => doom.keys.KEY_STRAFE_L,
        sdl.SDLK_D => doom.keys.KEY_STRAFE_R,

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
