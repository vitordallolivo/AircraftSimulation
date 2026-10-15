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

pub const Tube = struct {
    origin: V3,
    axis: V3, // unitário, para onde o tubo vai
    R: f64, // raio no disco
    length: f64 = 1e3,
    ctx: *const anyopaque = undefined, // dados da função de raio
    radiusFn: ?*const fn (ctx: *const anyopaque, x: f64) f64 = null, // null: cilindro de raio R

    pub fn radius(t: Tube, x: f64) f64 {
        return if (t.radiusFn) |f| f(t.ctx, x) else t.R;
    }

    /// (distância ao longo do eixo, distância ao eixo) do ponto p
    pub fn local(t: Tube, p: V3) [2]f64 {
        const d = p - t.origin;
        const x = vec.dot(d, t.axis);
        const rad = d - t.axis * vec.splat(x);
        return .{ x, vec.norm(rad) };
    }

    pub fn contains(t: Tube, p: V3) bool {
        const l = t.local(p);
        return l[0] >= 0 and l[0] <= t.length and l[1] <= t.radius(l[0]);
    }
};

pub const Strip = struct {
    center: V3, // a 25 % da corda
    ex: V3, // corda, para a frente
    ey: V3, // envergadura
    chord: f64,
    width: f64,

    /// ponto (i, j) da grade nc × ns, no meio de cada célula: corda do bordo de ataque ao de fuga
    pub fn sample(s: Strip, i: usize, j: usize, nc: usize, ns: usize) V3 {
        const fc = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(nc)); // 0 = bordo de ataque
        const fs = (@as(f64, @floatFromInt(j)) + 0.5) / @as(f64, @floatFromInt(ns)) - 0.5;
        const c = (0.25 - fc) * s.chord; // + à frente do centro
        return s.center + s.ex * vec.splat(c) + s.ey * vec.splat(fs * s.width);
    }
};

/// fração da faixa (área) dentro do tubo, numa grade nc × ns
pub fn stripFraction(t: Tube, s: Strip, nc: usize, ns: usize) f64 {
    var k: usize = 0;
    for (0..nc) |i| {
        for (0..ns) |j| {
            if (t.contains(s.sample(i, j, nc, ns))) k += 1;
        }
    }
    return @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(nc * ns));
}

const testing = std.testing;

fn cylinder(R: f64) Tube {
    return .{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = R };
}

test "cilindro: dentro, fora, à frente do disco, comprimento" {
    const t = Tube{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = 0.2, .length = 1.0 };
    try testing.expect(t.contains(.{ -0.5, 0.1, 0.1 }));
    try testing.expect(!t.contains(.{ -0.5, 0.2, 0.1 })); // √(0,04 + 0,01) > 0,2
    try testing.expect(!t.contains(.{ 0.1, 0, 0 })); // à frente
    try testing.expect(!t.contains(.{ -1.5, 0, 0 })); // além do comprimento
}

test "faixa inteira dentro, fora, metade, acima da linha de tração" {
    const t = cylinder(0.2);
    const base = Strip{ .center = .{ -0.5, 0, 0 }, .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 }, .chord = 0.2, .width = 0.1 };
    try testing.expectEqual(@as(f64, 1), stripFraction(t, base, 4, 16));
    var far = base;
    far.center = .{ -0.5, 1.0, 0 };
    try testing.expectEqual(@as(f64, 0), stripFraction(t, far, 4, 16));
    var half = base;
    half.center = .{ -0.5, 0.2, 0 };
    half.width = 0.4; // de y = 0 a 0,4: metade dentro
    try testing.expectApproxEqAbs(0.5, stripFraction(t, half, 4, 64), 0.02);
    var above = base;
    above.center = .{ -0.5, 0, -0.25 }; // acima do eixo (z para baixo): fora do cilindro de 0,2
    try testing.expectEqual(@as(f64, 0), stripFraction(t, above, 4, 16));
}

const Cone = struct {
    k: f64,
    fn r(ctx: *const anyopaque, x: f64) f64 {
        const self: *const Cone = @ptrCast(@alignCast(ctx));
        return 0.2 - self.k * x;
    }
};

test "tubo que contrai: o raio vem de quem chama" {
    const c = Cone{ .k = 0.1 };
    const t = Tube{ .origin = .{ 0, 0, 0 }, .axis = .{ -1, 0, 0 }, .R = 0.2, .ctx = &c, .radiusFn = Cone.r };
    try testing.expect(t.contains(.{ -1.0, 0.09, 0 })); // raio 0,1 em x = 1
    try testing.expect(!t.contains(.{ -1.0, 0.11, 0 }));
}
