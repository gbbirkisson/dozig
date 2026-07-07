//! Doom lookup tables (port of doom/tables.c), generated at comptime.
//!
//! ELI5: Doom stores which way you face as one big precise number (a "BAM" —
//! a full turn is 2^32, so turning stays smooth). To move or draw, it chops that
//! number into one of FINEANGLES (8192) "slices" (`angle >> ANGLETOFINESHIFT`)
//! and looks up the answer here:
//!   finecosine / finesine  - the X / Y of one step in that direction (movement, rendering)
//!   finetangent            - the slope of that direction (rendering)
//!   tantoangle + SlopeDiv  - the reverse: an X/Y offset -> a BAM angle ("what points at that?")
//!   gammatable             - unrelated: screen brightness (gamma) correction
//!
//! e.g. to walk forward (P_Thrust, C-side): chop the facing angle to a slice,
//! then add the X/Y of one step, scaled by speed:
//!   fine = angle >> ANGLETOFINESHIFT;            // 19: a 2^32 turn -> 8192 slices
//!   momx += FixedMul(speed, finecosine[fine]);  // step in X
//!   momy += FixedMul(speed, finesine[fine]);    // step in Y

const std = @import("std");

const FINEANGLES = 8192;
const SLOPERANGE = 2048;

/// BAM angle -> fine-table index, for Zig callers: `finesine[angle >> ANGLETOFINESHIFT]`.
/// A full turn is 2^32 (BAM) and there are FINEANGLES (8192 = 2^13) slices, so 32 - 13 = 19.
/// Same value the C engine defines as a macro in doom/tables.h (macros don't cross to Zig).
const ANGLETOFINESHIFT = 19;

const TWO_PI: f64 = std.math.tau;
const FRACUNIT_F: f64 = 65536.0;

/// Sine LUT: sin(fine angle) as 16.16 fixed-point, so values run -65535..65535
/// (≈ ±1.0). 10240 entries = 5/4 of a turn (a full turn is 8192); the extra 1/4
/// lets finecosine alias into the tail.
///
/// Generated at comptime via @sin. `finesine_inc`/`finesine_dec` then nudge the
/// ~33 entries where Zig's (correctly-rounded) @sin disagrees with id
/// Software's original 1993 math library by exactly ±1 — the playsim scales
/// movement directly by these values, so they must be bit-exact for demos to
/// stay in sync. Comment both fixup loops out to see the raw generated table.
pub export const finesine: [5 * FINEANGLES / 4]c_int = blk: {
    @setEvalBranchQuota(600_000);
    var t: [5 * FINEANGLES / 4]c_int = undefined;
    for (&t, 0..) |*e, i| {
        const a = (@as(f64, @floatFromInt(i)) + 0.5) * TWO_PI / FINEANGLES;
        e.* = @intFromFloat(@sin(a) * FRACUNIT_F);
    }
    if (true) { // set to false to disable id-1993 rounding fixups
        for (finesine_inc) |i| t[i] += 1;
        for (finesine_dec) |i| t[i] -= 1;
    }
    break :blk t;
};

// The 33 entries where Zig's @sin lands one unit off id Software's original
// 1993 finesine table: +1 for the first list, -1 for the second. (See finesine.)
const finesine_inc = [_]u16{ 455, 1080, 3212, 3324, 3640, 4959, 5174, 6722, 7140, 7170, 7328, 7396, 7947, 8077, 8262, 8821, 8823, 8963, 9259, 9272, 9451, 9465 };
const finesine_dec = [_]u16{ 2268, 3822, 4147, 4551, 7111, 7420, 8140, 8306, 9055, 9325, 10019 };

/// Cosine LUT: the same 16.16 sine values, read from a 90° (quarter-turn = 2048)
/// offset — a *pointer* into finesine, not its own array, so
/// finecosine[a] == finesine[a + 2048] == cos(angle).
pub export const finecosine: [*c]const c_int = &finesine[FINEANGLES / 4];

/// Tangent LUT: tan(fine angle) as 16.16 fixed-point over -90°..+90° (4096 =
/// half a turn, where tan is single-valued). Tiny near the middle (±25),
/// enormous toward the ±90° ends (~±170 million).
///
/// NOT vanilla-exact near ±PI/2 (renderer + deathmatch-only path; harmless).
pub export const finetangent: [FINEANGLES / 2]c_int = blk: {
    @setEvalBranchQuota(300_000);
    var t: [FINEANGLES / 2]c_int = undefined;
    for (&t, 0..) |*e, i| {
        const a = (@as(f64, @floatFromInt(i)) - 2048.0 + 0.5) * TWO_PI / FINEANGLES;
        e.* = @intFromFloat(@tan(a) * FRACUNIT_F);
    }
    break :blk t;
};

/// Inverse-tangent LUT (the reverse of the sine/tangent tables): given a slope
/// index 0..2048 (steepness 0..1 over the 0°-45° wedge, from SlopeDiv), the BAM
/// angle it points at, 0..ANG45 (0..0x20000000 ≈ 537M). Values are angle_t (u32).
///
/// NOT bit-identical to vanilla: id's 1993 atan rounds differently, so ~92% of
/// entries differ by a few units out of 2^32 (a ~1e-6 degree error). In practice
/// imperceptible — movement uses shift the angle right by ANGLETOFINESHIFT
/// before use, and the direct-angle uses (R_PointToAngle2 for aim/AI) only
/// diverge if a comparison lands within ~16 units of a boundary; strict vanilla
/// demo playback may therefore very slowly desync. Accepted deliberately to
/// keep this table comptime-generated.
pub export const tantoangle: [SLOPERANGE + 1]c_uint = blk: {
    @setEvalBranchQuota(300_000);
    var t: [SLOPERANGE + 1]c_uint = undefined;
    for (&t, 0..) |*e, i| {
        const x = @as(f64, @floatFromInt(i)) / @as(f64, SLOPERANGE);
        e.* = @intFromFloat(std.math.atan(x) / TWO_PI * 4294967296.0);
    }
    break :blk t;
};

/// Gamma ramps: 5 brightness curves, each mapping an input level 0..255 to a
/// gamma-corrected output level 0..255 (u8). Row 0 ≈ identity; higher rows brighten.
///
/// Display only; generated ramp, not vanilla-matched. Default usegamma==0.
pub export const gammatable: [5][256]u8 = blk: {
    @setEvalBranchQuota(80_000);
    const exps = [5]f64{ 1.0, 0.9, 0.8, 0.7, 0.6 };
    var t: [5][256]u8 = undefined;
    for (&t, exps) |*row, e| {
        for (row, 0..) |*v, i| {
            const base = (@as(f64, @floatFromInt(i)) + 1.0) / 256.0;
            v.* = @intFromFloat(@min(@round(255.0 * @exp(e * @log(base))), 255.0)); // 255*base^e
        }
    }
    break :blk t;
};

// ----- Idiomatic Zig API -----

/// Turn a direction's steepness into a row index into `tantoangle` (0..SLOPERANGE).
/// Only covers the 0°-45° wedge, so the caller passes the smaller coordinate as
/// `sideways` and the larger as `ahead`, both non-negative (R_PointToAngle folds
/// the other 7 octants into this one). Result ≈ (sideways / ahead) * SLOPERANGE:
/// straight ahead -> 0, a 45° diagonal (sideways == ahead) -> SLOPERANGE.
/// C engine equivalent: SlopeDiv (doom/tables.c).
pub fn slopeDiv(sideways: c_uint, ahead: c_uint) c_int {
    // 'ahead' too small to scale by: `ahead >> 8` would be 0 (divide-by-zero) or
    // 1 (huge result). Such a direction already sits at the 45° edge, so snap to
    // the last row instead of dividing.
    if (ahead < 512) return SLOPERANGE;

    // row ≈ (sideways / ahead) * 2048, as cheap integer math split into ×8 and
    // ÷256 (8 * 256 == 2048) so the intermediate values stay small and can't overflow.
    const scaled = sideways *% 8; // ×8   (*% is wrapping mul, matching C's unsigned `<<3`)
    const ans = scaled / (ahead >> 8); // ÷256 -> the (sideways/ahead)*2048 row index

    // clamp: never return an index past the end of the 2049-row tantoangle table.
    return if (ans <= SLOPERANGE) @intCast(ans) else SLOPERANGE;
}

// ----- C-ABI bridge -----

export fn SlopeDiv(num: c_uint, den: c_uint) c_int {
    return slopeDiv(num, den);
}

// ----- Tests -----

test "finesine sampled parity vs vanilla (exact after fixups)" {
    const s = [_]struct { i: usize, v: c_int }{
        .{ .i = 0, .v = 25 },      .{ .i = 1, .v = 75 },        .{ .i = 2, .v = 125 },
        .{ .i = 455, .v = 22433 }, .{ .i = 2047, .v = 65535 },  .{ .i = 2048, .v = 65535 },
        .{ .i = 4096, .v = -25 },  .{ .i = 6144, .v = -65535 }, .{ .i = 8191, .v = -25 },
        .{ .i = 8192, .v = 25 },   .{ .i = 10019, .v = 64600 }, .{ .i = 10239, .v = 65535 },
    };
    for (s) |c| try std.testing.expectEqual(c.v, finesine[c.i]);
}

test "finecosine is finesine shifted a quarter turn" {
    try std.testing.expectEqual(finesine[FINEANGLES / 4], finecosine[0]);
    try std.testing.expectEqual(finesine[FINEANGLES / 4 + 100], finecosine[100]);
}

test "tantoangle self-consistency (not vanilla-exact by design)" {
    try std.testing.expectEqual(@as(c_uint, 0), tantoangle[0]);
    try std.testing.expect(tantoangle[SLOPERANGE] > 536_870_000 and tantoangle[SLOPERANGE] < 536_871_800);
    var i: usize = 1;
    while (i <= SLOPERANGE) : (i += 1) try std.testing.expect(tantoangle[i] >= tantoangle[i - 1]);
}

test "finetangent self-consistency" {
    try std.testing.expectEqual(@as(c_int, 25), finetangent[2048]);
    try std.testing.expectEqual(@as(c_int, -25), finetangent[2047]);
    try std.testing.expect(finetangent[0] < -100_000_000);
    try std.testing.expect(finetangent[4095] > 100_000_000);
    var i: usize = 1;
    while (i < finetangent.len) : (i += 1) try std.testing.expect(finetangent[i] >= finetangent[i - 1]);
}

test "gammatable self-consistency" {
    for (gammatable) |row| {
        try std.testing.expectEqual(@as(u8, 255), row[255]);
        var i: usize = 1;
        while (i < 256) : (i += 1) try std.testing.expect(row[i] >= row[i - 1]);
    }
    var i: usize = 0;
    while (i < 256) : (i += 1) try std.testing.expect(gammatable[4][i] >= gammatable[0][i]);
}

test "slopeDiv" {
    try std.testing.expectEqual(@as(c_int, SLOPERANGE), slopeDiv(1, 100)); // den<512
    try std.testing.expectEqual(@as(c_int, 400), slopeDiv(100, 512)); // (100*8)/(512>>8)=800/2=400
    try std.testing.expectEqual(@as(c_int, SLOPERANGE), slopeDiv(2000, 1024)); // 16000/4=4000 -> clamp
}
