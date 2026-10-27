//! Terreno: chão plano (h = 0) com mesas/plataformas retangulares elevadas.
//! A decolagem pode começar em cima de uma mesa e o pouso pode ser numa plataforma;
//! o trem, o efeito solo e o arredondamento olham a altura do terreno sob cada ponto.
const std = @import("std");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");

/// altura do terreno no ponto (north, east): a da mesa mais alta que o contém, ou 0
pub fn height(params: *const types.Params, north: f64, east: f64) f64 {
    var max_height: f64 = 0.0;
    const n_pads: usize = @intCast(@max(params.n_pad, 0));
    for (params.pads[0..n_pads]) |*pad| {
        const heading = fmath.sincos(pad.chi);
        const dn = north - pad.n0;
        const de = east - pad.e0;
        const along = dn * heading.c + de * heading.s;
        const cross = -dn * heading.s + de * heading.c;
        if (along >= 0.0 and along <= pad.L and @abs(cross) <= 0.5 * pad.W) max_height = @max(max_height, pad.h);
    }
    return max_height;
}

test "mesa: dentro e fora" {
    var params = types.Params{};
    params.n_pad = 1;
    params.pads[0] = .{ .n0 = -1, .e0 = 0, .chi = 0, .L = 5, .W = 2, .h = 0.8 };
    try std.testing.expectEqual(@as(f64, 0.8), height(&params, 0, 0));
    try std.testing.expectEqual(@as(f64, 0.0), height(&params, 4.5, 0));
    try std.testing.expectEqual(@as(f64, 0.0), height(&params, 1, 1.5));
}
