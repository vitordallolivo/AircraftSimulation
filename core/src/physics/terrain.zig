//! Terreno: chão plano (h = 0) com mesas/plataformas retangulares elevadas.
//! A decolagem pode começar em cima de uma mesa e o pouso pode ser numa plataforma;
//! o trem, o efeito solo e o arredondamento olham a altura do terreno sob cada ponto.
const std = @import("std");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");

/// altura do terreno em (n, e)
pub fn height(p: *const types.Params, n: f64, e: f64) f64 {
    var hmax: f64 = 0.0;
    const np: usize = @intCast(@max(p.n_pad, 0));
    for (p.pads[0..np]) |*q| {
        const sc = fmath.sincos(q.chi);
        const dn = n - q.n0;
        const de = e - q.e0;
        const along = dn * sc.c + de * sc.s;
        const cross = -dn * sc.s + de * sc.c;
        if (along >= 0.0 and along <= q.L and @abs(cross) <= 0.5 * q.W) hmax = @max(hmax, q.h);
    }
    return hmax;
}

test "mesa: dentro e fora" {
    var p = types.Params{};
    p.n_pad = 1;
    p.pads[0] = .{ .n0 = -1, .e0 = 0, .chi = 0, .L = 5, .W = 2, .h = 0.8 };
    try std.testing.expectEqual(@as(f64, 0.8), height(&p, 0, 0));
    try std.testing.expectEqual(@as(f64, 0.0), height(&p, 4.5, 0));
    try std.testing.expectEqual(@as(f64, 0.0), height(&p, 1, 1.5));
}
