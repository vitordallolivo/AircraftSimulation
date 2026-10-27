//! Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro sem mexer no resto
//! do núcleo. O Python monta os modificadores (dados); aqui ficam só os tipos conhecidos (código estático,
//! um `switch` por tipo). Ver README.md desta pasta.
//!
//! Onde entram (`physics/aero.zig`, em cada painel):
//!   v_painel = V_ar + ω × r + Σ v_induzida(r)        (só se houver modificador ligado: `p.n_mod > 0`)
//!   C_Di ← φ_solo(h) C_Di                            (método escolhido em `p.ground`)
const std = @import("std");
const limits = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const types = @import("types.zig");
pub const ground = @import("ground.zig");
pub const slipstream = @import("slipstream.zig");
pub const wingpair = @import("wingpair.zig");
pub const flapmoment = @import("flapmoment.zig");
const core_types = @import("../types.zig");
const prop = @import("../physics/propulsion.zig");

/// o que os modificadores podem olhar no instante (preenchido por quem chama a aerodinâmica)
pub const Env = struct {
    n_prop: usize = 0,
    T: [limits.max_props]f64 = [_]f64{0} ** limits.max_props, // tração de cada motor (N)
    Q: [limits.max_props]f64 = [_]f64{0} ** limits.max_props, // torque (N·m)
    Vax: [limits.max_props]f64 = [_]f64{0} ** limits.max_props, // velocidade do ar ao longo do eixo, no cubo (m/s)
    eT: [limits.max_props]V3 = [_]V3{vec.zero} ** limits.max_props, // eixo de tração (corpo)
    // par de asas ligadas (wingpair.zig): circulação de cada painel e para onde o ar vai; a aerodinâmica preenche
    gamma: [limits.max_surfaces]f64 = [_]f64{0} ** limits.max_surfaces,
    u: V3 = vec.zero,
    no_pair: bool = false, // a linha sustentadora vem depois (loads/llt.zig): o par já está no sistema dela

    pub const none: Env = .{};
};

/// Env a partir da tração e do torque de cada motor (o estado do avião dá o eixo e a velocidade no cubo)
pub fn envFrom(p: *const core_types.Params, Vr: V3, w: V3, Tn: []const f64, Qn: []const f64) Env {
    var e = Env{};
    e.n_prop = @intCast(p.n_prop);
    for (p.prop[0..e.n_prop], 0..) |*u, i| {
        const eT = prop.axis(p, u);
        e.eT[i] = eT;
        e.Vax[i] = vec.dot(Vr + vec.cross(w, vec.v3(u.r)), eT);
        e.T[i] = Tn[i];
        e.Q[i] = Qn[i];
    }
    return e;
}

/// o painel `i` está na máscara?
pub inline fn hits(mask: [2]i32, i: usize) bool {
    if (mask[0] == 0 and mask[1] == 0) return true;
    const w: u32 = @bitCast(mask[i / 32]);
    return (w >> @intCast(i % 32)) & 1 != 0;
}

/// o motor `j` está na máscara?
pub inline fn hitsProp(mask: i32, j: usize) bool {
    if (mask == 0) return true;
    const w: u32 = @bitCast(mask);
    return (w >> @intCast(j)) & 1 != 0;
}

/// grade de pontos em cada faixa onde a esteira é avaliada: na corda (do bordo de ataque ao de fuga) e na
/// envergadura (a faixa pode estar só em parte dentro do tubo, acima ou abaixo da linha de tração: a média dá a
/// parte imersa). A grade é a do modelo de colisão (collision/collision.zig)
pub const chord_samples = 3;
pub const strip_samples = 16;
const collision = @import("../collision/collision.zig");

/// a faixa do painel `s` como forma de colisão
pub fn stripOf(s: *const core_types.Surface) collision.Strip {
    return .{ .center = vec.v3(s.r), .ex = vec.v3(s.ex), .ey = vec.v3(s.ey), .chord = s.c,
        .width = if (s.c > 0) s.S / s.c else 0.0 };
}

/// o que entra na velocidade relativa do painel `i`, somando os modificadores ligados.
/// O painel vê v = V_ar + ω × r − v_ar_induzida; aqui sai −v_ar_induzida (média ao longo da faixa).
pub fn induced(p: *const core_types.Params, env: *const Env, i: usize, s: *const core_types.Surface) V3 {
    return inducedWith(true, p, env, i, s);
}

/// `induced` sem o par de asas (o α de cada painel antes da interferência, para as circulações do par)
pub fn inducedNoPair(p: *const core_types.Params, env: *const Env, i: usize, s: *const core_types.Surface) V3 {
    return inducedWith(false, p, env, i, s);
}

fn inducedWith(comptime pair: bool, p: *const core_types.Params, env: *const Env, i: usize, s: *const core_types.Surface) V3 {
    var v = vec.zero;
    const n: usize = @intCast(p.n_mod);
    for (p.mods[0..n]) |*m| {
        if (m.enabled == 0 or !hits(m.surf_mask, i)) continue;
        v += switch (m.kindOf()) {
            .slipstream_disk => slipstreamStrip(p, env, m, s),
            .wing_pair => if (pair and p.aero_model == 0) wingpair.induced(p, m, env.gamma[0..], env.u, i) else vec.zero,
            .flap_moment, .none, _ => vec.zero, // tipo vazio ou desconhecido: nada
        };
    }
    return v;
}

/// Δc_m da faixa i pelo comando (flapmoment.zig), já com o curso: soma dos `flap_moment` ligados que pegam a faixa;
/// 0 sem nenhum (aí a faixa fica bit a bit como era)
pub fn flapCm(p: *const core_types.Params, i: usize, s: *const core_types.Surface, d: V3) f64 {
    var cm: f64 = 0.0;
    const n: usize = @intCast(p.n_mod);
    for (p.mods[0..n]) |*m| {
        if (m.enabled == 0 or m.kindOf() != .flap_moment or !hits(m.surf_mask, i)) continue;
        cm += flapmoment.cmDelta(s.tau, m.params[0]) * vec.dot(vec.v3(s.mix), d);
    }
    return cm;
}

/// média da esteira na faixa, na grade chord_samples × strip_samples (corda × envergadura)
fn slipstreamStrip(p: *const core_types.Params, env: *const Env, m: *const types.Modifier, s: *const core_types.Surface) V3 {
    const st = stripOf(s);
    var v = vec.zero;
    for (0..chord_samples) |i| {
        for (0..strip_samples) |j| v += slipstreamAt(p, env, m, st.sample(i, j, chord_samples, strip_samples));
    }
    return v / vec.splat(@as(f64, chord_samples * strip_samples));
}

/// soma das esteiras dos motores da máscara no ponto r (superposição, slipstream.zig)
fn slipstreamAt(p: *const core_types.Params, env: *const Env, m: *const types.Modifier, r: V3) V3 {
    var v = vec.zero;
    const ax = m.slip(.axial_on) != 0;
    const sw = m.slip(.swirl_on) != 0;
    for (0..env.n_prop) |j| {
        if (!hitsProp(m.prop_mask, j) or env.T[j] <= 0) continue;
        const u = &p.prop[j];
        const s = slipstream.at(env.T[j], env.Q[j], env.Vax[j], 0.5 * u.D, p.env.rho, u.sense, env.eT[j],
            r - vec.v3(u.r), ax, sw);
        if (!s.inside) continue;
        // ar empurrado para trás (−eT) e girando: o painel vê +axial eT e −giro
        v += env.eT[j] * vec.splat(m.slip(.axial_gain) * s.axial) - s.swirl * vec.splat(m.slip(.swirl_gain));
    }
    return v;
}

const testing = std.testing;

test "máscara de painéis" {
    try testing.expect(hits(.{ 0, 0 }, 40)); // vazia = todos
    try testing.expect(hits(.{ 0b101, 0 }, 2));
    try testing.expect(!hits(.{ 0b101, 0 }, 1));
    try testing.expect(hits(.{ 0, 1 }, 32));
    try testing.expect(!hits(.{ 0, 1 }, 33));
}

test {
    _ = ground;
    _ = slipstream;
    _ = wingpair;
    _ = flapmoment;
}
