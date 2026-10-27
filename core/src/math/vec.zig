//! Vetores 3D em registradores SIMD (@Vector) e matrizes 3x3 por linhas.
const std = @import("std");
const fmath = @import("fmath.zig");

pub const V3 = @Vector(3, f64);
pub const M3 = [3]V3; // linhas

pub const zero: V3 = @splat(0.0);

/// o vetor SIMD a partir de um array de 3
pub inline fn v3(components: [3]f64) V3 {
    return components;
}
/// o array de 3 a partir do vetor SIMD
pub inline fn arr(vector: V3) [3]f64 {
    return vector;
}
/// o vetor com as três componentes iguais a `value`
pub inline fn splat(value: f64) V3 {
    return @splat(value);
}
/// produto escalar
pub inline fn dot(left: V3, right: V3) f64 {
    return @reduce(.Add, left * right);
}
/// módulo (norma euclidiana)
pub inline fn norm(vector: V3) f64 {
    return @sqrt(dot(vector, vector));
}
/// produto vetorial left × right
pub inline fn cross(left: V3, right: V3) V3 {
    const left_yzx = @shuffle(f64, left, undefined, [3]i32{ 1, 2, 0 });
    const left_zxy = @shuffle(f64, left, undefined, [3]i32{ 2, 0, 1 });
    const right_yzx = @shuffle(f64, right, undefined, [3]i32{ 1, 2, 0 });
    const right_zxy = @shuffle(f64, right, undefined, [3]i32{ 2, 0, 1 });
    return left_yzx * right_zxy - left_zxy * right_yzx;
}

/// matriz × vetor: R v
pub inline fn mul(matrix: M3, vector: V3) V3 {
    return .{ dot(matrix[0], vector), dot(matrix[1], vector), dot(matrix[2], vector) };
}
/// transposta × vetor: Rᵀ v
pub inline fn mulT(matrix: M3, vector: V3) V3 {
    return matrix[0] * splat(vector[0]) + matrix[1] * splat(vector[1]) + matrix[2] * splat(vector[2]);
}

/// matriz corpo -> NED a partir dos ângulos de Euler
pub fn rotation(phi: f64, theta: f64, psi: f64) M3 {
    const roll = fmath.sincos(phi);
    const pitch = fmath.sincos(theta);
    const yaw = fmath.sincos(psi);
    const sph = roll.s;
    const cph = roll.c;
    const sth = pitch.s;
    const cth = pitch.c;
    const sps = yaw.s;
    const cps = yaw.c;
    return .{
        .{ cth * cps, sph * sth * cps - cph * sps, cph * sth * cps + sph * sps },
        .{ cth * sps, sph * sth * sps + cph * cps, cph * sth * sps - sph * cps },
        .{ -sth, sph * cth, cph * cth },
    };
}

/// resolve A x = b (3x3) pela inversa por produtos vetoriais
pub fn solve3(matrix: M3, rhs: V3) V3 {
    const cofactor0 = cross(matrix[1], matrix[2]);
    const cofactor1 = cross(matrix[2], matrix[0]);
    const cofactor2 = cross(matrix[0], matrix[1]);
    const det = dot(matrix[0], cofactor0);
    return (cofactor0 * splat(rhs[0]) + cofactor1 * splat(rhs[1]) + cofactor2 * splat(rhs[2])) / splat(det);
}

const testing = std.testing;

test "cross e solve3" {
    const left = V3{ 1, 2, 3 };
    const right = V3{ -2, 0.5, 4 };
    const product = cross(left, right);
    try testing.expectApproxEqAbs(@as(f64, 2 * 4 - 3 * 0.5), product[0], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 3 * -2 - 1 * 4), product[1], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 1 * 0.5 - 2 * -2), product[2], 1e-14);
    const matrix = M3{ .{ 4, 1, 0.2 }, .{ 0.5, 3, -1 }, .{ 0.1, -0.3, 2 } };
    const expected = V3{ 0.3, -1.2, 2.5 };
    const solved = solve3(matrix, mul(matrix, expected));
    inline for (0..3) |i| try testing.expectApproxEqAbs(expected[i], solved[i], 1e-12);
}

test "rotation ortogonal" {
    const matrix = rotation(0.3, -0.2, 1.1);
    const original = V3{ 1, -2, 0.5 };
    const back = mulT(matrix, mul(matrix, original));
    inline for (0..3) |i| try testing.expectApproxEqAbs(original[i], back[i], 1e-12);
}
