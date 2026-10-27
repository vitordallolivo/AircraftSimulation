//! Vento 3D numa direção (perfil 1/7 com a altura) e rajada 1-cos.
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const types = @import("../types.zig");

/// vento em NED no instante `time` e na altura `height`. wind_from = direção DE ONDE o vento vem, wind_elev = elevação (+ sobe).
/// tg < 0: sem rajada em andamento.
pub fn wind(env: *const types.Environment, time: f64, height: f64, tg: f64) vec.V3 {
    const height_min = if (height > 0.1) height else 0.1;
    const speed = if (env.Vw10 != 0) env.Vw10 * fmath.pow(height_min / env.h_ref, 1.0 / 7.0) else 0.0;
    const from_dir = fmath.sincos(env.wind_from);
    const elevation = fmath.sincos(env.wind_elev);
    var wind_ned = vec.V3{ -speed * elevation.c * from_dir.c, -speed * elevation.c * from_dir.s, -speed * elevation.s };
    if (env.gust_on != 0 and tg >= 0.0 and time >= tg and time <= tg + env.gust_T) {
        const gust_fraction = 0.5 * (1.0 - fmath.cos(2.0 * fmath.pi * (time - tg) / env.gust_T));
        wind_ned += vec.v3(env.gust_U) * vec.splat(gust_fraction);
    }
    return wind_ned;
}

const std = @import("std");
test "vento vem de onde diz" {
    const env = types.Environment{ .Vw10 = 5, .wind_from = 0, .h_ref = 10 };
    const wind_ned = wind(&env, 0, 10, -1);
    try std.testing.expectApproxEqAbs(@as(f64, -5), wind_ned[0], 1e-9); // vento de norte sopra para sul
    try std.testing.expectApproxEqAbs(@as(f64, 0), wind_ned[1], 1e-9);
}
