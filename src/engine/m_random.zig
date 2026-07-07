//! Doom's two random-number generators (port of doom/m_random.c).
//!
//! ELI5: Doom's "random" isn't really random — it's a fixed list of 256 numbers
//! (rndtable, baked in 1993). A generator just walks the list one step at a time,
//! wrapping back to the start at the end, and hands back the next number. Same
//! list, same order, every run.
//!
//! There are TWO independent walkers, so cosmetic randomness never disturbs the
//! game world:
//!   play() (P_Random) - used by the simulation (monsters, damage, aim); must
//!                       stay in lockstep so recorded demos replay identically.
//!   misc() (M_Random) - looks only (menus, screen wipe, HUD, intermission).
//! Keeping the two indices separate means a flickery menu can't shift the numbers
//! the monsters get. clear() sends both back to the start (at demo/game start).

const std = @import("std");

const rndtable = [256]u8{
    0,   8,   109, 220, 222, 241, 149, 107, 75,  248, 254, 140, 16,  66,
    74,  21,  211, 47,  80,  242, 154, 27,  205, 128, 161, 89,  77,  36,
    95,  110, 85,  48,  212, 140, 211, 249, 22,  79,  200, 50,  28,  188,
    52,  140, 202, 120, 68,  145, 62,  70,  184, 190, 91,  197, 152, 224,
    149, 104, 25,  178, 252, 182, 202, 182, 141, 197, 4,   81,  181, 242,
    145, 42,  39,  227, 156, 198, 225, 193, 219, 93,  122, 175, 249, 0,
    175, 143, 70,  239, 46,  246, 163, 53,  163, 109, 168, 135, 2,   235,
    25,  92,  20,  145, 138, 77,  69,  166, 78,  176, 173, 212, 166, 113,
    94,  161, 41,  50,  239, 49,  111, 164, 70,  60,  2,   37,  171, 75,
    136, 156, 11,  56,  42,  146, 138, 229, 73,  146, 77,  61,  98,  196,
    135, 106, 63,  197, 195, 86,  96,  203, 113, 101, 170, 247, 181, 113,
    80,  250, 108, 7,   255, 237, 129, 226, 79,  107, 112, 166, 103, 241,
    24,  223, 239, 120, 198, 58,  60,  82,  128, 3,   184, 66,  143, 224,
    145, 224, 81,  206, 163, 45,  63,  90,  168, 114, 59,  33,  159, 95,
    28,  139, 123, 98,  125, 196, 15,  70,  194, 253, 54,  14,  109, 226,
    71,  17,  161, 93,  186, 87,  244, 138, 20,  52,  123, 251, 26,  36,
    17,  46,  52,  231, 232, 76,  31,  221, 84,  37,  216, 165, 212, 106,
    197, 242, 98,  43,  39,  175, 254, 145, 190, 84,  118, 222, 187, 136,
    120, 163, 236, 249,
};

// prndindex has no external references -> private state.
var prndindex: u8 = 0;

// ----- Idiomatic Zig API -----

/// Play-simulation RNG. Deterministic; drives demo/netgame sync.
/// C engine equivalent: P_Random (doom/m_random.c).
pub fn play() u8 {
    prndindex +%= 1; // u8 wraparound == C's (prndindex + 1) & 0xff
    return rndtable[prndindex];
}

/// Non-simulation RNG: menus, HUD, screen wipe, intermission. Advances the
/// consistency-checked index (`rndindex`).
/// C engine equivalent: M_Random (doom/m_random.c).
pub fn misc() u8 {
    rndindex = (rndindex + 1) & 0xff;
    return rndtable[@intCast(rndindex)];
}

/// Reset both sequences, called at demo/game start.
/// C engine equivalent: M_ClearRandom (doom/m_random.c).
pub fn clear() void {
    rndindex = 0;
    prndindex = 0;
}

// ----- C-ABI bridge -----

// Read directly by the C engine (g_game.c consistency check; `extern int
// rndindex` in doomstat.h). This is the live state `misc()` mutates — one
// location, so C keeps seeing the correct value. When the bridge is removed,
// drop the `export` and keep it as private state.
export var rndindex: c_int = 0;

export fn P_Random() c_int {
    return play();
}

export fn M_Random() c_int {
    return misc();
}

export fn M_ClearRandom() void {
    clear();
}

// ----- Tests -----

test "play() reproduces Doom's P_Random sequence" {
    clear();
    // prndindex increments before the lookup, so the first draw is rndtable[1].
    try std.testing.expectEqual(@as(u8, 8), play());
    try std.testing.expectEqual(@as(u8, 109), play());
    try std.testing.expectEqual(@as(u8, 220), play());
}

test "misc() reproduces Doom's M_Random sequence and advances rndindex" {
    clear();
    try std.testing.expectEqual(@as(u8, 8), misc());
    try std.testing.expectEqual(@as(u8, 109), misc());
    try std.testing.expectEqual(@as(c_int, 2), rndindex);
}

test "clear() resets both sequences" {
    clear();
    _ = play();
    _ = misc();
    clear();
    try std.testing.expectEqual(@as(c_int, 0), rndindex);
    try std.testing.expectEqual(@as(u8, 8), play()); // back to the start
}
