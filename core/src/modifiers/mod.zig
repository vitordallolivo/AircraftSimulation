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
pub const interference = @import("interference.zig");
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
    // interferência entre asas (interference.zig): circulação de cada painel e para onde o ar vai; a aerodinâmica preenche
    gamma: [limits.max_surfaces]f64 = [_]f64{0} ** limits.max_surfaces,
    u: V3 = vec.zero,
    no_interference: bool = false, // a linha sustentadora vem depois (loads/llt.zig): a interferência já está no sistema dela

    pub const none: Env = .{};
};

/// Env a partir da tração e do torque de cada motor (o estado do avião dá o eixo e a velocidade no cubo)
pub fn envFrom(params: *const core_types.Params, Vr: V3, body_rates: V3, thrusts: []const f64, torques: []const f64) Env {
    var env = Env{};
    env.n_prop = @intCast(params.n_prop);
    for (params.prop[0..env.n_prop], 0..) |*prop_unit, i| {
        const eT = prop.axis(params, prop_unit);
        env.eT[i] = eT;
        env.Vax[i] = vec.dot(Vr + vec.cross(body_rates, vec.v3(prop_unit.r)), eT);
        env.T[i] = thrusts[i];
        env.Q[i] = torques[i];
    }
    return env;
}

/// grade de pontos em cada faixa onde a esteira é avaliada: na corda (do bordo de ataque ao de fuga) e na
/// envergadura (a faixa pode estar só em parte dentro do tubo, acima ou abaixo da linha de tração: a média dá a
/// parte imersa). A grade é a do modelo de colisão (collision/collision.zig)
pub const chord_samples = 3;
pub const strip_samples = 16;
const collision = @import("../collision/collision.zig");

/// a faixa do painel `surface` como forma de colisão
pub fn stripOf(surface: *const core_types.Surface) collision.Strip {
    return .{ .center = vec.v3(surface.r), .ex = vec.v3(surface.ex), .ey = vec.v3(surface.ey), .chord = surface.c,
        .width = if (surface.c > 0) surface.S / surface.c else 0.0 };
}

/// o que entra na velocidade relativa do painel `i`, somando os modificadores ligados.
/// O painel vê v = V_ar + ω × r − v_ar_induzida; aqui sai −v_ar_induzida (média ao longo da faixa).
pub fn induced(params: *const core_types.Params, env: *const Env, i: usize, surface: *const core_types.Surface) V3 {
    return inducedWith(true, params, env, i, surface);
}

/// `induced` sem a interferência entre asas (o α de cada painel antes dela, para as circulações)
pub fn inducedAlone(params: *const core_types.Params, env: *const Env, i: usize, surface: *const core_types.Surface) V3 {
    return inducedWith(false, params, env, i, surface);
}

fn inducedWith(comptime with_interference: bool, params: *const core_types.Params, env: *const Env, i: usize, surface: *const core_types.Surface) V3 {
    var velocity = vec.zero;
    const n_mods: usize = @intCast(params.n_mod);
    for (params.mods[0..n_mods]) |*modifier| {
        if (!modifier.flags.enabled or !modifier.affectsPanel(i)) continue;
        velocity += switch (modifier.kind) {
            .slipstream_disk => slipstreamStrip(params, env, modifier, surface),
            .wing_interference => if (with_interference and params.aero_model == .strips) interference.induced(params, modifier, env.gamma[0..], env.u, i) else vec.zero,
            .flap_moment, .none, _ => vec.zero, // tipo vazio ou desconhecido: nada
        };
    }
    return velocity;
}

/// Δc_m da faixa i pelo comando (flapmoment.zig), já com o curso: soma dos `flap_moment` ligados que pegam a faixa;
/// 0 sem nenhum (aí a faixa fica bit a bit como era)
pub fn flapCm(params: *const core_types.Params, i: usize, surface: *const core_types.Surface, deflections: V3) f64 {
    var delta_cm: f64 = 0.0;
    const n_mods: usize = @intCast(params.n_mod);
    for (params.mods[0..n_mods]) |*modifier| {
        if (!modifier.isOn(.flap_moment) or !modifier.affectsPanel(i)) continue;
        delta_cm += flapmoment.cmDelta(surface.tau, modifier.settings(types.FlapMomentSettings).factor) * vec.dot(vec.v3(surface.mix), deflections);
    }
    return delta_cm;
}

/// média da esteira na faixa, na grade chord_samples × strip_samples (corda × envergadura)
fn slipstreamStrip(params: *const core_types.Params, env: *const Env, modifier: *const types.Modifier, surface: *const core_types.Surface) V3 {
    const strip = stripOf(surface);
    var velocity = vec.zero;
    for (0..chord_samples) |i| {
        for (0..strip_samples) |j| velocity += slipstreamAt(params, env, modifier, strip.sample(i, j, chord_samples, strip_samples));
    }
    return velocity / vec.splat(@as(f64, chord_samples * strip_samples));
}

/// soma das esteiras dos motores da máscara no ponto `position` (superposição, slipstream.zig)
fn slipstreamAt(params: *const core_types.Params, env: *const Env, modifier: *const types.Modifier, position: V3) V3 {
    var velocity = vec.zero;
    const use_axial = modifier.flags.axial;
    const use_swirl = modifier.flags.swirl;
    const gains = modifier.settings(types.SlipstreamSettings);
    for (0..env.n_prop) |j| {
        if (!modifier.affectsProp(j) or env.T[j] <= 0) continue;
        const prop_unit = &params.prop[j];
        const wake = slipstream.at(env.T[j], env.Q[j], env.Vax[j], 0.5 * prop_unit.D, params.env.rho, prop_unit.sense, env.eT[j],
            position - vec.v3(prop_unit.r), use_axial, use_swirl);
        if (!wake.inside) continue;
        // ar empurrado para trás (−eT) e girando: o painel vê +axial eT e −giro
        velocity += env.eT[j] * vec.splat(gains.axial_gain * wake.axial) - wake.swirl * vec.splat(gains.swirl_gain);
    }
    return velocity;
}

const testing = std.testing;

test "conjunto de painéis e de motores" {
    const empty: types.Modifier = .{};
    try testing.expect(empty.affectsPanel(40) and empty.affectsProp(3)); // vazio = todos
    const some: types.Modifier = .{ .surf_mask = .{ 0b101, 1 }, .prop_mask = 0b10 };
    try testing.expect(some.affectsPanel(2) and !some.affectsPanel(1));
    try testing.expect(some.affectsPanel(32) and !some.affectsPanel(33));
    try testing.expect(some.affectsProp(1) and !some.affectsProp(0));
    try testing.expect(types.panelSet(.{ -1, 0 }).isSet(31)); // o bit de sinal do i32 é o painel 31
}

test {
    _ = ground;
    _ = slipstream;
    _ = interference;
    _ = flapmoment;
}
