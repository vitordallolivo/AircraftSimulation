//! Percurso (corrente de segmentos) e guiamento lateral.
//!
//! Reta: campo vetorial  χd = χp − χ∞ (2/π) atan(k e)
//! Arco: órbita           χd = φ + λ (π/2 + atan(k_o (d − R) / max(R, L_orb)))
//! (Beard e McLain, cap. 10). Altura e velocidade de cada segmento vão de (h0, V0) a
//! (h1, V1) por uma curva cosseno; no segmento de pouso a altura cai em rampa.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("../sim/state.zig");
const fm = @import("../math/fmath.zig");

pub const Guide = struct {
    s: f64 = 0,
    ect: f64 = 0,
    chip: f64 = 0,
    chid: f64 = 0,
    phiff: f64 = 0,
    hseg: f64 = 0,
    Vseg: f64 = 0,
};

fn smooth(x: f64) f64 {
    return 0.5 * (1.0 - fm.cos(fm.pi * fm.lim(x, 0.0, 1.0)));
}

pub fn guide(c: S.Ctx, n: f64, e: f64, Vg: f64) Guide {
    const p = c.p;
    const ap = &p.ap;
    var g = Guide{};
    if (p.n_seg <= 0) return g;
    const k: usize = @intCast(c.f.seg);
    const sg = &p.seg[k];
    const has_next = c.f.seg + 1 < p.n_seg;
    if (sg.arc == 0) {
        const sc = fm.sincos(sg.chi0);
        g.s = (n - sg.n0) * sc.c + (e - sg.e0) * sc.s;
        g.ect = -(n - sg.n0) * sc.s + (e - sg.e0) * sc.c; // + : à direita
        g.chip = sg.chi0;
        g.chid = sg.chi0 - ap.chi_inf * (2.0 / fm.pi) * fm.atan(ap.kvf * g.ect);
        // antecipação: se a próxima perna é curva, começa a inclinar t_lead s antes
        if (has_next and p.seg[k + 1].arc != 0 and ap.tlead > 0.0) {
            const nx = &p.seg[k + 1];
            const w = 1.0 - (sg.L - g.s) / (Vg * ap.tlead + 1e-6);
            g.phiff = fm.lim(w, 0.0, 1.0) * nx.lam * fm.atan(Vg * Vg / (L.g0 * nx.R));
        }
    } else {
        const fi = fm.atan2(e - sg.ce, n - sg.cn);
        const fi0 = fm.atan2(sg.e0 - sg.ce, sg.n0 - sg.cn);
        const d = fm.hypot(n - sg.cn, e - sg.ce);
        var dl = sg.lam * (fi - fi0);
        while (dl < -0.5 * fm.pi) dl += 2.0 * fm.pi;
        while (dl >= 1.5 * fm.pi) dl -= 2.0 * fm.pi;
        g.s = sg.R * dl;
        g.ect = sg.lam * (d - sg.R); // + : por fora
        g.chip = fi + sg.lam * 0.5 * fm.pi;
        // ganho da órbita em 1/m limitado: em raio pequeno k_o/R ficaria agressivo demais
        g.chid = fi + sg.lam * (0.5 * fm.pi + fm.atan(ap.korb * (d - sg.R) / @max(sg.R, ap.Lorb)));
        g.phiff = sg.lam * fm.atan(Vg * Vg / (L.g0 * sg.R));
        if (ap.tlead > 0.0 and has_next and p.seg[k + 1].arc == 0)
            g.phiff *= fm.lim((sg.L - g.s) / (Vg * ap.tlead + 1e-6), 0.0, 1.0);
    }
    const xs = g.s / sg.L;
    g.hseg = sg.h0 + (sg.h1 - sg.h0) * smooth(xs);
    g.Vseg = sg.V0 + (sg.V1 - sg.V0) * smooth(xs);
    if (sg.landing != 0)
        g.hseg = sg.h0 + (c.h_ground + 0.1 - sg.h0) * fm.lim(g.s / (sg.L - sg.clearance), 0.0, 1.0);
    return g;
}

test "reta: erro lateral e distância" {
    var p = T.Params{};
    p.n_seg = 1;
    p.seg[0] = .{ .L = 100, .chi0 = 0, .h0 = 10, .h1 = 10, .V0 = 15, .V1 = 15 };
    const f = S.Flags{};
    const ctx = S.Ctx{ .p = &p, .f = &f, .tR = -1, .h_ground = 0, .tg = -1 };
    const g = guide(ctx, 30, 2, 15);
    try std.testing.expectApproxEqAbs(@as(f64, 30), g.s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), g.ect, 1e-9);
    try std.testing.expect(g.chid < 0);
}
