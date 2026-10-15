//! Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro sem mexer no resto
//! do núcleo. O Python monta os modificadores (dados); aqui ficam só os tipos conhecidos (código estático,
//! um `switch` por tipo). Ver README.md desta pasta.
//!
//! Onde entram (`physics/aero.zig`, em cada painel):
//!   v_painel = V_ar + ω × r + Σ v_induzida(r)        (só se houver modificador ligado: `p.n_mod > 0`)
//!   C_Di ← φ_solo(h) C_Di                            (método escolhido em `p.ground`)
const std = @import("std");
const L = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const types = @import("types.zig");
pub const ground = @import("ground.zig");
pub const slipstream = @import("slipstream.zig");
const T = @import("../types.zig");
const prop = @import("../physics/propulsion.zig");

/// o que os modificadores podem olhar no instante (preenchido por quem chama a aerodinâmica)
pub const Env = struct {
    n_prop: usize = 0,
    T: [L.max_props]f64 = [_]f64{0} ** L.max_props, // tração de cada motor (N)
    Q: [L.max_props]f64 = [_]f64{0} ** L.max_props, // torque (N·m)
    Vax: [L.max_props]f64 = [_]f64{0} ** L.max_props, // velocidade do ar ao longo do eixo, no cubo (m/s)
    eT: [L.max_props]V3 = [_]V3{vec.zero} ** L.max_props, // eixo de tração (corpo)

    pub const none: Env = .{};
};

/// Env a partir da tração e do torque de cada motor (o estado do avião dá o eixo e a velocidade no cubo)
pub fn envFrom(p: *const T.Params, Vr: V3, w: V3, Tn: []const f64, Qn: []const f64) Env {
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
pub fn stripOf(s: *const T.Surface) collision.Strip {
    return .{ .center = vec.v3(s.r), .ex = vec.v3(s.ex), .ey = vec.v3(s.ey), .chord = s.c,
        .width = if (s.c > 0) s.S / s.c else 0.0 };
}

/// o que entra na velocidade relativa do painel `i`, somando os modificadores ligados.
/// O painel vê v = V_ar + ω × r − v_ar_induzida; aqui sai −v_ar_induzida (média ao longo da faixa).
pub fn induced(p: *const T.Params, env: *const Env, i: usize, s: *const T.Surface) V3 {
    var v = vec.zero;
    const n: usize = @intCast(p.n_mod);
    for (p.mods[0..n]) |*m| {
        if (m.enabled == 0 or !hits(m.surf_mask, i)) continue;
        v += switch (m.kind) {
            types.kind_slipstream_disk => slipstreamStrip(p, env, m, s),
            else => vec.zero, // tipo vazio ou desconhecido: nada
        };
    }
    return v;
}

/// média da esteira na faixa, na grade chord_samples × strip_samples (corda × envergadura)
fn slipstreamStrip(p: *const T.Params, env: *const Env, m: *const types.Modifier, s: *const T.Surface) V3 {
    const st = stripOf(s);
    var v = vec.zero;
    for (0..chord_samples) |i| {
        for (0..strip_samples) |j| v += slipstreamAt(p, env, m, st.sample(i, j, chord_samples, strip_samples));
    }
    return v / vec.splat(@as(f64, chord_samples * strip_samples));
}

/// soma das esteiras dos motores da máscara no ponto r (superposição, slipstream.zig)
fn slipstreamAt(p: *const T.Params, env: *const Env, m: *const types.Modifier, r: V3) V3 {
    var v = vec.zero;
    const ax = m.params[0] != 0;
    const sw = m.params[1] != 0;
    for (0..env.n_prop) |j| {
        if (!hitsProp(m.prop_mask, j) or env.T[j] <= 0) continue;
        const u = &p.prop[j];
        const s = slipstream.at(env.T[j], env.Q[j], env.Vax[j], 0.5 * u.D, p.env.rho, u.sense, env.eT[j],
            r - vec.v3(u.r), ax, sw);
        if (!s.inside) continue;
        // ar empurrado para trás (−eT) e girando: o painel vê +axial eT e −giro
        v += env.eT[j] * vec.splat(m.params[2] * s.axial) - s.swirl * vec.splat(m.params[3]);
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
}
