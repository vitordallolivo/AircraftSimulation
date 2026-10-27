//! Colisão geométrica: o que fica dentro do tubo de uma hélice (cilindro do raio dela ou o tubo que contrai da
//! esteira) e quanto de cada faixa aerodinâmica está dentro dele. Só geometria; quem diz a física do tubo
//! (raio ao longo do eixo) é quem chama (`modifiers/slipstream.zig`).
//!
//! Tubo: começa no disco (`origin`), segue `axis` (unitário, para onde o ar vai: para trás numa hélice tratora),
//! com raio `radius(x)` em cada distância x ao longo do eixo; até `length`. À frente do disco (x < 0) não há tubo.
//! Faixa: quadrilátero com centro a 25 % da corda (`center`), direção da corda para a frente (`ex`), da envergadura
//! (`ey`), corda `chord` e largura `width`. A fração imersa sai de uma grade de pontos na faixa (nc × ns).
const std = @import("std");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

/// tubo de uma hélice: origem no disco, eixo, raio no disco e, opcional, o raio ao longo do eixo
pub const Tube = struct {
    origin: V3,
    axis: V3, // unitário, para onde o tubo vai
    R: f64, // raio no disco
    length: f64 = 1e3,
    ctx: *const anyopaque = undefined, // dados da função de raio
    radiusFn: ?*const fn (ctx: *const anyopaque, distance: f64) f64 = null, // null: cilindro de raio R

    /// raio do tubo a `distance` do disco (a função de quem chama ou, sem ela, o raio R)
    pub fn radius(self: Tube, distance: f64) f64 {
        return if (self.radiusFn) |radius_fn| radius_fn(self.ctx, distance) else self.R;
    }

    /// (distância ao longo do eixo, distância ao eixo) do ponto `point`
    pub fn local(self: Tube, point: V3) [2]f64 {
        const offset = point - self.origin;
        const along = vec.dot(offset, self.axis);
        const rad = offset - self.axis * vec.splat(along);
        return .{ along, vec.norm(rad) };
    }

    /// verdadeiro se `point` está dentro do tubo (entre o disco e `length`)
    pub fn contains(self: Tube, point: V3) bool {
        const coords = self.local(point);
        return coords[0] >= 0 and coords[0] <= self.length and coords[1] <= self.radius(coords[0]);
    }
};

/// faixa aerodinâmica como quadrilátero: centro, eixos da corda e da envergadura, corda e largura
pub const Strip = struct {
    center: V3, // a 25 % da corda
    ex: V3, // corda, para a frente
    ey: V3, // envergadura
    chord: f64,
    width: f64,

    /// ponto (i, j) da grade n_chord × n_span, no meio de cada célula: corda do bordo de ataque ao de fuga
    pub fn sample(self: Strip, i: usize, j: usize, n_chord: usize, n_span: usize) V3 {
        const chord_frac = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n_chord)); // 0 = bordo de ataque
        const span_frac = (@as(f64, @floatFromInt(j)) + 0.5) / @as(f64, @floatFromInt(n_span)) - 0.5;
        const chord_offset = (0.25 - chord_frac) * self.chord; // + à frente do centro
        return self.center + self.ex * vec.splat(chord_offset) + self.ey * vec.splat(span_frac * self.width);
    }
};

/// fração da faixa (área) dentro do tubo, numa grade n_chord × n_span
pub fn stripFraction(tube: Tube, strip: Strip, n_chord: usize, n_span: usize) f64 {
    var inside: usize = 0;
    for (0..n_chord) |i| {
        for (0..n_span) |j| {
            if (tube.contains(strip.sample(i, j, n_chord, n_span))) inside += 1;
        }
    }
    return @as(f64, @floatFromInt(inside)) / @as(f64, @floatFromInt(n_chord * n_span));
}

const testing = std.testing;

fn cylinder(radius: f64) Tube {
    return .{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = radius };
}

test "cilindro: dentro, fora, à frente do disco, comprimento" {
    const tube = Tube{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = 0.2, .length = 1.0 };
    try testing.expect(tube.contains(.{ -0.5, 0.1, 0.1 }));
    try testing.expect(!tube.contains(.{ -0.5, 0.2, 0.1 })); // √(0,04 + 0,01) > 0,2
    try testing.expect(!tube.contains(.{ 0.1, 0, 0 })); // à frente
    try testing.expect(!tube.contains(.{ -1.5, 0, 0 })); // além do comprimento
}

test "faixa inteira dentro, fora, metade, acima da linha de tração" {
    const tube = cylinder(0.2);
    const base = Strip{ .center = .{ -0.5, 0, 0 }, .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 }, .chord = 0.2, .width = 0.1 };
    try testing.expectEqual(@as(f64, 1), stripFraction(tube, base, 4, 16));
    var far = base;
    far.center = .{ -0.5, 1.0, 0 };
    try testing.expectEqual(@as(f64, 0), stripFraction(tube, far, 4, 16));
    var half = base;
    half.center = .{ -0.5, 0.2, 0 };
    half.width = 0.4; // de y = 0 a 0,4: metade dentro
    try testing.expectApproxEqAbs(0.5, stripFraction(tube, half, 4, 64), 0.02);
    var above = base;
    above.center = .{ -0.5, 0, -0.25 }; // acima do eixo (z para baixo): fora do cilindro de 0,2
    try testing.expectEqual(@as(f64, 0), stripFraction(tube, above, 4, 16));
}

const Cone = struct {
    slope: f64,
    fn radius(ctx: *const anyopaque, distance: f64) f64 {
        const self: *const Cone = @ptrCast(@alignCast(ctx));
        return 0.2 - self.slope * distance;
    }
};

test "tubo que contrai: o raio vem de quem chama" {
    const cone = Cone{ .slope = 0.1 };
    const tube = Tube{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = 0.2, .ctx = &cone, .radiusFn = Cone.radius };
    try testing.expect(tube.contains(.{ -1.0, 0.09, 0 })); // raio 0,1 em x = 1
    try testing.expect(!tube.contains(.{ -1.0, 0.11, 0 }));
}
