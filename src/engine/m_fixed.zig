//! Fixed-point (16.16) arithmetic (port of doom/m_fixed.c).
//!
//! A `Fixed` is an i32 that stores a real number scaled by FRACUNIT (2^16):
//! the value v is kept as v * 65536. So 1.0 = 65536, 0.5 = 32768, -2.0 = -131072.
//!
//! Why only mul/div get functions: add, subtract, compare, and negate keep the
//! same 2^16 scale on both sides, so the plain operators already give a valid
//! `Fixed` — (a/2^16) ± (b/2^16) = (a±b)/2^16, i.e. just `a + b`, `a - b`, `a < b`.
//! Scaling a `Fixed` by a bare integer (`x * 2`, `x >> 1`) is plain too.
//!
//! Multiplying or dividing two `Fixed`s changes the scale, so those need a shift
//! back to 16.16 (and a 64-bit intermediate so the shift can't overflow):
//!   Fixed * Fixed: scales multiply -> 2^32, so shift the product back  >> 16   (fixedMul)
//!   Fixed / Fixed: scales cancel   -> plain ratio, so pre-shift dividend << 16   (fixedDiv)

const std = @import("std");

pub const FRACBITS = 16;
pub const FRACUNIT = 1 << FRACBITS; // 65536
pub const Fixed = i32; // Doom's fixed_t

// ----- Idiomatic Zig API -----

/// C engine equivalent: FixedMul (doom/m_fixed.c).
pub fn fixedMul(a: Fixed, b: Fixed) Fixed {
    // (fixed_t)(((int64_t)a * b) >> FRACBITS) — @truncate matches C's wrap-on-overflow cast.
    return @truncate((@as(i64, a) * @as(i64, b)) >> FRACBITS);
}

/// C engine equivalent: FixedDiv (doom/m_fixed.c).
pub fn fixedDiv(a: Fixed, b: Fixed) Fixed {
    if ((@abs(a) >> 14) >= @abs(b)) {
        return if ((a ^ b) < 0) std.math.minInt(Fixed) else std.math.maxInt(Fixed);
    }
    // Guard guarantees |result| < 2^30, so @intCast is safe. C '/' truncates toward zero.
    return @intCast(@divTrunc(@as(i64, a) << 16, @as(i64, b)));
}

// ----- C-ABI bridge -----

export fn FixedMul(a: c_int, b: c_int) c_int {
    return fixedMul(a, b);
}

export fn FixedDiv(a: c_int, b: c_int) c_int {
    return fixedDiv(a, b);
}

// ----- Tests -----

test "fixedMul" {
    try std.testing.expectEqual(@as(Fixed, FRACUNIT), fixedMul(FRACUNIT, FRACUNIT)); // 1*1=1
    try std.testing.expectEqual(@as(Fixed, 393216), fixedMul(2 * FRACUNIT, 3 * FRACUNIT)); // 2*3=6
    try std.testing.expectEqual(@as(Fixed, 16384), fixedMul(FRACUNIT / 2, FRACUNIT / 2)); // .5*.5=.25
    try std.testing.expectEqual(@as(Fixed, -FRACUNIT), fixedMul(-FRACUNIT, FRACUNIT));
}

test "fixedDiv normal" {
    try std.testing.expectEqual(@as(Fixed, 32768), fixedDiv(FRACUNIT, 2 * FRACUNIT)); // 1/2=.5
    try std.testing.expectEqual(@as(Fixed, 196608), fixedDiv(3 * FRACUNIT, FRACUNIT)); // 3/1=3
}

test "fixedDiv overflow guard" {
    // |a|>>14 >= |b|  -> clamp to INT_MIN/MAX by sign of a^b
    try std.testing.expectEqual(std.math.maxInt(Fixed), fixedDiv(0x7FFFFFFF, FRACUNIT));
    try std.testing.expectEqual(std.math.minInt(Fixed), fixedDiv(-0x7FFFFFFF, FRACUNIT));
}
