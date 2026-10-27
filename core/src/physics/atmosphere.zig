//! Vento 3D numa direção (perfil 1/7 com a altura) e rajada 1-cos.
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const types = @import("../types.zig");

/// W em NED. wind_from = direção DE ONDE o vento vem, wind_elev = elevação (+ sobe).
/// tg < 0: sem rajada em andamento.
pub fn wind(env: *const types.Environment, t: f64, h: f64, tg: f64) vec.V3 {
    const hh = if (h > 0.1) h else 0.1;
    const V = if (env.Vw10 != 0) env.Vw10 * fmath.pow(hh / env.h_ref, 1.0 / 7.0) else 0.0;
    const a = fmath.sincos(env.wind_from);
    const b = fmath.sincos(env.wind_elev);
    var W = vec.V3{ -V * b.c * a.c, -V * b.c * a.s, -V * b.s };
    if (env.gust_on != 0 and tg >= 0.0 and t >= tg and t <= tg + env.gust_T) {
        const f = 0.5 * (1.0 - fmath.cos(2.0 * fmath.pi * (t - tg) / env.gust_T));
        W += vec.v3(env.gust_U) * vec.splat(f);
    }
    return W;
}

const std = @import("std");
test "vento vem de onde diz" {
    const env = types.Environment{ .Vw10 = 5, .wind_from = 0, .h_ref = 10 };
    const W = wind(&env, 0, 10, -1);
    try std.testing.expectApproxEqAbs(@as(f64, -5), W[0], 1e-9); // vento de norte sopra para sul
    try std.testing.expectApproxEqAbs(@as(f64, 0), W[1], 1e-9);
}
