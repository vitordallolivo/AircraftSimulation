//! Vetores 3D (f64) e rotações usados pelo modelo, pelo esqueleto e pelas câmeras.
//! Sem dependência de gráficos: dá para testar (e fazer fuzzing) sem janela.
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const V3 = [3]f64;

pub fn add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: V3, k: f64) V3 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}
pub fn mul(a: V3, b: V3) V3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}
pub fn dot(a: V3, b: V3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn norm(a: V3) f64 {
    return @sqrt(dot(a, a));
}
pub fn finite(a: V3) bool {
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}

/// unitário; `fallback` se o vetor for nulo ou não finito
pub fn unit(a: V3, fallback: V3) V3 {
    const n = norm(a);
    if (!(n > 1e-12) or !std.math.isFinite(n)) return fallback;
    return scale(a, 1.0 / n);
}

/// matriz 3×3 por linhas
pub const M3 = [3]V3;

pub fn apply(m: M3, v: V3) V3 {
    return .{ dot(m[0], v), dot(m[1], v), dot(m[2], v) };
}

pub fn matmul(a: M3, b: M3) M3 {
    var r: M3 = undefined;
    for (0..3) |i| {
        for (0..3) |j| r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    }
    return r;
}

/// rotação de `ang` (rad, regra da mão direita) em torno do eixo unitário `k` (Rodrigues)
pub fn axisAngle(k: V3, ang: f64) M3 {
    const c = @cos(ang);
    const s = @sin(ang);
    const t = 1.0 - c;
    const x = k[0];
    const y = k[1];
    const z = k[2];
    return .{
        .{ t * x * x + c, t * x * y - s * z, t * x * z + s * y },
        .{ t * x * y + s * z, t * y * y + c, t * y * z - s * x },
        .{ t * x * z - s * y, t * y * z + s * x, t * z * z + c },
    };
}

/// corpo -> NED pelos ângulos de Euler (φ, θ, ψ), sequência 3-2-1
pub fn bodyToNed(phi: f64, theta: f64, psi: f64) M3 {
    const cf = @cos(phi);
    const sf = @sin(phi);
    const ct = @cos(theta);
    const st = @sin(theta);
    const cp = @cos(psi);
    const sp = @sin(psi);
    return .{
        .{ ct * cp, sf * st * cp - cf * sp, cf * st * cp + sf * sp },
        .{ ct * sp, sf * st * sp + cf * cp, cf * st * sp - sf * cp },
        .{ -st, sf * ct, cf * ct },
    };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "rotação: 90° em y leva −x para +z (bordo de fuga desce)" {
    const r = apply(axisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0), .{ -1, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0), r[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), r[2], 1e-12);
}

test "corpo -> NED: ψ = 90° aponta o nariz para leste" {
    const r = apply(bodyToNed(0, 0, std.math.pi / 2.0), .{ 1, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 1), r[1], 1e-12);
}

fn fuzzRotation(_: void, src: *fz.Src) anyerror!void {
    // eixo e ângulo quaisquer (inclusive nulos e não finitos): a rotação de um eixo saneado
    // tem de preservar o comprimento e ser finita
    var k: V3 = undefined;
    for (&k) |*c| c.* = src.any();
    const ang: f64 = src.any();
    var v: V3 = undefined;
    for (&v) |*c| c.* = @floatFromInt(src.int(i16, -1000, 1000));
    const u = unit(k, .{ 0, 0, 1 });
    try testing.expect(finite(u));
    if (!std.math.isFinite(ang) or @abs(ang) > 1e6) return;   // ângulo inválido: quem chama satura antes
    const r = apply(axisAngle(u, ang), v);
    try testing.expect(finite(r));
    try testing.expectApproxEqAbs(norm(v), norm(r), 1e-6 * (1 + norm(v)));
}

test "fuzz: rotação preserva comprimento" {
    try fz.check({}, fuzzRotation, .{});
}
