//! Maps SDL3 keycodes to Doom key codes.

const c = @import("c");

// Doom key codes (values from doom/doomkeys.h; frozen 1993 keyboard ABI).
// Only the ones convertToDoomKey maps are listed.
const KEY_RIGHTARROW = 0xae;
const KEY_LEFTARROW = 0xac;
const KEY_UPARROW = 0xad;
const KEY_DOWNARROW = 0xaf;
const KEY_STRAFE_L = 0xa0;
const KEY_STRAFE_R = 0xa1;
const KEY_USE = 0xa2;
const KEY_FIRE = 0xa3;
const KEY_ESCAPE = 27;
const KEY_ENTER = 13;
const KEY_RSHIFT = 0x80 + 0x36;
const KEY_LALT = 0x80 + 0x38;
const KEY_F2 = 0x80 + 0x3c;
const KEY_F3 = 0x80 + 0x3d;
const KEY_F4 = 0x80 + 0x3e;
const KEY_F5 = 0x80 + 0x3f;
const KEY_F6 = 0x80 + 0x40;
const KEY_F7 = 0x80 + 0x41;
const KEY_F8 = 0x80 + 0x42;
const KEY_F9 = 0x80 + 0x43;
const KEY_F10 = 0x80 + 0x44;
const KEY_F11 = 0x80 + 0x57;
const KEY_EQUALS = 0x3d;
const KEY_MINUS = 0x2d;

pub fn convertToDoomKey(key: c.SDL_Keycode) u8 {
    return switch (key) {
        // Extra
        c.SDLK_W => KEY_UPARROW,
        c.SDLK_S => KEY_DOWNARROW,
        c.SDLK_A => KEY_STRAFE_L,
        c.SDLK_D => KEY_STRAFE_R,

        // Original
        c.SDLK_RETURN => KEY_ENTER,
        c.SDLK_ESCAPE => KEY_ESCAPE,
        c.SDLK_LEFT => KEY_LEFTARROW,
        c.SDLK_RIGHT => KEY_RIGHTARROW,
        c.SDLK_UP => KEY_UPARROW,
        c.SDLK_DOWN => KEY_DOWNARROW,
        c.SDLK_LCTRL, c.SDLK_RCTRL => KEY_FIRE,
        c.SDLK_SPACE => KEY_USE,
        c.SDLK_LSHIFT, c.SDLK_RSHIFT => KEY_RSHIFT,
        c.SDLK_LALT, c.SDLK_RALT => KEY_LALT,
        c.SDLK_F2 => KEY_F2,
        c.SDLK_F3 => KEY_F3,
        c.SDLK_F4 => KEY_F4,
        c.SDLK_F5 => KEY_F5,
        c.SDLK_F6 => KEY_F6,
        c.SDLK_F7 => KEY_F7,
        c.SDLK_F8 => KEY_F8,
        c.SDLK_F9 => KEY_F9,
        c.SDLK_F10 => KEY_F10,
        c.SDLK_F11 => KEY_F11,
        c.SDLK_EQUALS, c.SDLK_PLUS => KEY_EQUALS,
        c.SDLK_MINUS => KEY_MINUS,
        else => blk: {
            // Match the original tolower(key) default for letter keys.
            var k = key;
            if (k >= 'A' and k <= 'Z') k += ('a' - 'A');
            break :blk @truncate(k);
        },
    };
}
