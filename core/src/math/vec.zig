//! Vetores 3D em registradores SIMD (@Vector) e matrizes 3x3 por linhas.
const std = @import("std");
const fm = @import("fmath.zig");

pub const V3 = @Vector(3, f64);
pub const M3 = [3]V3; // linhas

pub const zero: V3 = @splat(0.0);

pub inline fn v3(a: [3]f64) V3 {
    return a;
}
pub inline fn arr(x: V3) [3]f64 {
    return x;
}
pub inline fn splat(s: f64) V3 {
    return @splat(s);
}
pub inline fn dot(a: V3, b: V3) f64 {
    return @reduce(.Add, a * b);
}
pub inline fn norm(a: V3) f64 {
    return @sqrt(dot(a, a));
}
pub inline fn cross(a: V3, b: V3) V3 {
    const a1 = @shuffle(f64, a, undefined, [3]i32{ 1, 2, 0 });
    const a2 = @shuffle(f64, a, undefined, [3]i32{ 2, 0, 1 });
    const b1 = @shuffle(f64, b, undefined, [3]i32{ 1, 2, 0 });
    const b2 = @shuffle(f64, b, undefined, [3]i32{ 2, 0, 1 });
    return a1 * b2 - a2 * b1;
}

/// R x
pub inline fn mul(R: M3, x: V3) V3 {
    return .{ dot(R[0], x), dot(R[1], x), dot(R[2], x) };
}
/// Rᵀ x
pub inline fn mulT(R: M3, x: V3) V3 {
    return R[0] * splat(x[0]) + R[1] * splat(x[1]) + R[2] * splat(x[2]);
}

/// matriz corpo -> NED a partir dos ângulos de Euler
pub fn rotation(phi: f64, theta: f64, psi: f64) M3 {
    const a = fm.sincos(phi);
    const b = fm.sincos(theta);
    const c = fm.sincos(psi);
    const sph = a.s;
    const cph = a.c;
    const sth = b.s;
    const cth = b.c;
    const sps = c.s;
    const cps = c.c;
    return .{
        .{ cth * cps, sph * sth * cps - cph * sps, cph * sth * cps + sph * sps },
        .{ cth * sps, sph * sth * sps + cph * cps, cph * sth * sps - sph * cps },
        .{ -sth, sph * cth, cph * cth },
    };
}

/// resolve A x = b (3x3) pela inversa por produtos vetoriais
pub fn solve3(A: M3, b: V3) V3 {
    const c0 = cross(A[1], A[2]);
    const c1 = cross(A[2], A[0]);
    const c2 = cross(A[0], A[1]);
    const det = dot(A[0], c0);
    return (c0 * splat(b[0]) + c1 * splat(b[1]) + c2 * splat(b[2])) / splat(det);
}

const testing = std.testing;

test "cross e solve3" {
    const a = V3{ 1, 2, 3 };
    const b = V3{ -2, 0.5, 4 };
    const c = cross(a, b);
    try testing.expectApproxEqAbs(@as(f64, 2 * 4 - 3 * 0.5), c[0], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 3 * -2 - 1 * 4), c[1], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 1 * 0.5 - 2 * -2), c[2], 1e-14);
    const A = M3{ .{ 4, 1, 0.2 }, .{ 0.5, 3, -1 }, .{ 0.1, -0.3, 2 } };
    const x = V3{ 0.3, -1.2, 2.5 };
    const y = solve3(A, mul(A, x));
    inline for (0..3) |i| try testing.expectApproxEqAbs(x[i], y[i], 1e-12);
}

test "rotation ortogonal" {
    const R = rotation(0.3, -0.2, 1.1);
    const x = V3{ 1, -2, 0.5 };
    const y = mulT(R, mul(R, x));
    inline for (0..3) |i| try testing.expectApproxEqAbs(x[i], y[i], 1e-12);
}
