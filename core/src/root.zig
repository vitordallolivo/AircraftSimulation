//! Interface C ABI do núcleo (o que o Python chama via ctypes).
//!
//! Memória estática: um conjunto fixo de `max_instances` simulações. O chamador pega
//! uma com `aerosim_acquire`, escreve os parâmetros direto na struct devolvida por
//! `aerosim_params` (layout em `aerosim_schema`), chama `aerosim_configure` e roda.
//! Internamente os erros são error sets do Zig (`AbiError`); na fronteira viram um código fixo (< 0 = erro),
//! porque uma `export fn` só devolve números ao C. A tabela erro → código é `abiCode`.
const std = @import("std");
const limits = @import("limits.zig");
const types = @import("types.zig");
const state = @import("sim/state.zig");
const abi = @import("abi.zig");
const runner = @import("sim/runner.zig");
const trim = @import("sim/trim.zig");
const aero = @import("physics/aero.zig");
const modifiers = @import("modifiers/mod.zig");
const collision = @import("collision/collision.zig");
const llt = @import("loads/llt.zig");
const sweep = @import("loads/sweep.zig");
const fmath = @import("math/fmath.zig");
const prop = @import("physics/propulsion.zig");
const mass = @import("physics/mass.zig");
const vec = @import("math/vec.zig");
const linear = @import("sim/linear.zig");
const autotune = @import("control/autotune.zig");

var slots: [limits.max_instances]runner.Instance = [_]runner.Instance{.{}} ** limits.max_instances;
var used: [limits.max_instances]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(false)} ** limits.max_instances;

/// tudo o que uma função da ABI pode devolver como erro: os da configuração e do estado (sim/runner.zig) e os da
/// própria fronteira
pub const AbiError = runner.ConfigError || runner.StateError || error{
    /// slot fora da faixa ou não reservado
    InvalidSlot,
    /// todas as `max_instances` simulações estão em uso
    NoFreeSlot,
    /// índice de motor fora da faixa, tamanho de vetor que não bate ou faixa de V inválida
    BadIndex,
    /// as dimensões pedidas não cabem nos limites estáticos do método (otimizadores, amostragem)
    OutOfRange,
    /// não deu para reservar a memória de trabalho
    OutOfMemory,
    /// o sistema linear do método ficou singular, ou os pontos não determinam o ajuste
    SingularSystem,
};

/// o código que o Python recebe (aerosim/backend/zig/backend.py, `_ERRORS`). A tabela é escrita à mão porque
/// `@intFromError` dá números que mudam de uma compilação para outra, e o Python precisa de números fixos.
pub fn abiCode(err: AbiError) i32 {
    return switch (err) {
        error.InvalidSlot, error.NoFreeSlot => -1,
        error.NotConfigured => -2,
        error.BadSegment => -3,
        error.TrimFailed => -4,
        error.BadIndex => -5,
        error.NoGear => -6,
        error.BadInertia => -7,
        error.Diverged => -8,
        error.TooManySurfaces => -10,
        error.TooManyProps => -11,
        error.TooManyGear => -12,
        error.TooManyTanks => -13,
        error.TooManySegments => -14,
        error.TooManyEvents => -15,
        error.BadTimeStep => -16,
        error.BadMass => -17,
        error.TooManyPropPoints => -18,
        // os otimizadores sempre devolveram −1 para "não cabe"; o Python só olha o sinal
        error.OutOfRange, error.OutOfMemory, error.SingularSystem => -1,
    };
}

/// a simulação reservada no slot
fn get(slot: i32) AbiError!*runner.Instance {
    if (slot < 0 or slot >= limits.max_instances) return error.InvalidSlot;
    const index: usize = @intCast(slot);
    if (!used[index].load(.acquire)) return error.InvalidSlot;
    return &slots[index];
}

/// a simulação reservada e já configurada (`aerosim_configure`)
fn getConfigured(slot: i32) AbiError!*runner.Instance {
    const inst = try get(slot);
    return if (inst.configured) inst else error.NotConfigured;
}

/// versão do ABI (o Python confere ao carregar)
export fn aerosim_abi_version() u32 {
    return abi.version;
}

/// texto do esquema das structs exportadas (campos, tamanhos, offsets)
export fn aerosim_schema() [*:0]const u8 {
    return abi.schema.ptr;
}

/// sonda dos modificadores (sem simulação): fator do efeito solo do método `method` a `height` (m), envergadura `span` (m)
export fn aerosim_probe_ground(method: i32, height: f64, span: f64) f64 {
    return modifiers.ground.factor(method, height, span);
}

/// sonda da esteira (sem simulação): um motor de diâmetro D com tração T, torque Q e sentido `sense`, eixo +x,
/// ar a V ao longo do eixo; no ponto (dx, dy, dz) em relação ao cubo (corpo) devolve
/// out = [velocidade axial a mais (m/s, para trás), giro y, giro z (m/s), raio do tubo ali (m)]
export fn aerosim_probe_slipstream(thrust: f64, torque: f64, diameter: f64, airspeed: f64, rho: f64, sense: f64, dx: f64, dy: f64, dz: f64, out: *[4]f64) i32 {
    const wake = modifiers.slipstream.at(thrust, torque, airspeed, 0.5 * diameter, rho, sense, .{ 1, 0, 0 }, .{ dx, dy, dz }, true, true);
    out.* = .{ wake.axial, wake.swirl[1], wake.swirl[2], wake.R };
    return if (wake.inside) 1 else 0;
}

/// coeficientes como `aerosim_aero_coeffs_ex`, com a tração T[i] e o torque Q[i] de cada motor (n valores) para os
/// modificadores (esteira); ref nulo: CG
export fn aerosim_aero_coeffs_thrust(slot: i32, airspeed: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (prop_count != inst.p.n_prop) return abiCode(error.BadIndex);
    const moment_ref = if (ref) |ref_point| vec.v3(ref_point.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const prop_len: usize = @intCast(prop_count);
    out.* = aero.coeffsEnv(&inst.p, airspeed, alpha, beta, vec.zero, moment_ref, .{ de, da, dr }, .{ thrusts[0..prop_len], torques[0..prop_len] });
    return 0;
}

/// coeficientes com as taxas (p, q, r em rad/s), a altura `height` do avião sobre o chão (m; efeito solo) e a tração T[i] e
/// o torque Q[i] de cada motor (n = 0: sem motores; senão n = número de motores) para os modificadores; ref nulo: CG
export fn aerosim_aero_coeffs_at(slot: i32, airspeed: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, height: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (prop_count != 0 and prop_count != inst.p.n_prop) return abiCode(error.BadIndex);
    const moment_ref = if (ref) |ref_point| vec.v3(ref_point.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const prop_len: usize = @intCast(prop_count);
    const tq: ?[2][]const f64 = if (prop_count > 0) .{ thrusts[0..prop_len], torques[0..prop_len] } else null;
    out.* = aero.coeffsAt(&inst.p, airspeed, alpha, beta, .{ pr, qr, rr }, moment_ref, .{ de, da, dr }, height, tq);
    return 0;
}

/// colisão (collision/): fração de cada painel dentro do tubo do motor `idx` — o tubo da esteira com tração T a V
/// (contrai), ou, com T ≤ 0, o cilindro do raio da hélice — até `length` m atrás do disco. Escreve até `cap` valores
/// em `out` (grade 4 × 16 por painel); devolve o número de painéis
export fn aerosim_tube_panel_hits(slot: i32, idx: i32, thrust: f64, airspeed: f64, length: f64, out: [*]f64, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const prop_unit = &inst.p.prop[@intCast(idx)];
    const wake_shape = modifiers.slipstream.shape(thrust, airspeed, 0.5 * prop_unit.D, inst.p.env.rho);
    const tube = wake_shape.tube(vec.v3(prop_unit.r), prop.axis(&inst.p, prop_unit), length);
    const surf_count: usize = @intCast(inst.p.n_surf);
    for (inst.p.surf[0..@min(surf_count, cap)], 0..) |*surface, i| out[i] = collision.stripFraction(tube, modifiers.stripOf(surface), 4, 16);
    return @intCast(surf_count);
}

/// colisão: quais dos n pontos (x, y, z do corpo, em sequência) estão dentro do tubo do motor `idx` (ver acima);
/// out[i] = 1 dentro, 0 fora; devolve quantos estão dentro
export fn aerosim_tube_point_hits(slot: i32, idx: i32, thrust: f64, airspeed: f64, length: f64, pts: [*]const f64, count: usize, out: [*]i32) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const prop_unit = &inst.p.prop[@intCast(idx)];
    const wake_shape = modifiers.slipstream.shape(thrust, airspeed, 0.5 * prop_unit.D, inst.p.env.rho);
    const tube = wake_shape.tube(vec.v3(prop_unit.r), prop.axis(&inst.p, prop_unit), length);
    var inside_count: i32 = 0;
    for (0..count) |i| {
        const inside = tube.contains(.{ pts[3 * i], pts[3 * i + 1], pts[3 * i + 2] });
        out[i] = if (inside) 1 else 0;
        if (inside) inside_count += 1;
    }
    return inside_count;
}

/// estado do motor `idx` com o avião a V, α, β (sem rotação): rotação `rps` imposta (> 0) ou, se ≤ 0, a de
/// equilíbrio com o acelerador `thr`. Tração e torque pela hélice (C_T(J), C_P(J)) com o ar no eixo do motor.
/// Com a rotação imposta só a hélice conta: corrente e potência elétrica saem zeradas (o motor não está em
/// equilíbrio). No polinômio de tração a rotação não entra (T do polinômio, Q = 0).
export fn aerosim_prop_state(slot: i32, idx: i32, airspeed: f64, alpha: f64, beta: f64, rps: f64, thr: f64, out: *types.PropPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const prop_unit = &inst.p.prop[@intCast(idx)];
    const alpha_sc = fmath.sincos(alpha);
    const beta_sc = fmath.sincos(beta);
    const Vr = vec.V3{ airspeed * alpha_sc.c * beta_sc.c, airspeed * beta_sc.s, airspeed * alpha_sc.s * beta_sc.c };
    const eT = prop.axis(&inst.p, prop_unit);
    const imposed = rps > 0;
    const rotation = if (imposed) rps else prop.equilibriumRps(&inst.p, prop_unit, Vr, thr);
    const prop_out = prop.unit(&inst.p, prop_unit, eT, Vr, vec.zero, rotation, if (imposed) 1.0 else thr, 0);
    const Vax = vec.dot(Vr, eT);
    const Ps = prop_out.Q * 2.0 * fmath.pi * rotation;
    out.* = .{ .V = Vax, .rpm = rotation * 60.0, .J = prop_out.J, .T = prop_out.T, .Q = prop_out.Q, .P_shaft = Ps, .P_elec = if (imposed) 0 else prop_out.P, .I = if (imposed) 0 else prop_out.I, .eta_prop = if (Ps > 1e-6) prop_out.T * Vax / Ps else 0 };
    return 0;
}

/// estado de cada painel a V, α, β (sem rotação, longe do chão), com a tração T[i] e o torque Q[i] de cada motor
/// (n = número de motores; n = 0: sem motores). Escreve até `cap` painéis em `out`; devolve quantos há.
export fn aerosim_panel_states(slot: i32, airspeed: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, out: [*]types.PanelState, cap: usize) i32 {
    return panelStates(slot, airspeed, alpha, beta, de, da, dr, thrusts, torques, prop_count, out, cap, false);
}

/// `aerosim_panel_states`; `no_pair`: sem a interferência entre asas ligadas (a linha sustentadora vem depois)
fn panelStates(slot: i32, airspeed: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, out: [*]types.PanelState, cap: usize, no_pair: bool) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (prop_count != 0 and prop_count != inst.p.n_prop) return abiCode(error.BadIndex);
    const alpha_sc = fmath.sincos(alpha);
    const beta_sc = fmath.sincos(beta);
    const Vr = vec.V3{ airspeed * alpha_sc.c * beta_sc.c, airspeed * beta_sc.s, airspeed * alpha_sc.s * beta_sc.c };
    const prop_len: usize = @intCast(prop_count);
    var env = if (prop_count > 0) modifiers.envFrom(&inst.p, Vr, vec.zero, thrusts[0..prop_len], torques[0..prop_len]) else modifiers.Env.none;
    env.no_pair = no_pair;
    const surf_count: usize = @intCast(inst.p.n_surf);
    const written = @min(cap, surf_count);
    const rcg = trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    _ = aero.computeTrace(&inst.p, Vr, vec.zero, rcg, 50.0, .{ de, da, dr }, &env, out[0..written]);
    return @intCast(surf_count);
}

/// `aerosim_panel_states` com a carga da linha sustentadora (loads/llt.zig: ferraduras, Phillips e Snyder 2000) no
/// lugar do C_Lα uniforme de cada painel: a distribuição ao longo da envergadura depende do alongamento e da forma.
/// Só para análise de cargas; a simulação não usa.
export fn aerosim_panel_states_llt(slot: i32, airspeed: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, out: [*]types.PanelState, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const surf_count: usize = @intCast(inst.p.n_surf);
    if (cap < surf_count) return abiCode(error.BadIndex);
    const panel_count = panelStates(slot, airspeed, alpha, beta, de, da, dr, thrusts, torques, prop_count, out, cap, true);
    if (panel_count < 0) return panel_count;
    const alpha_sc = fmath.sincos(alpha);
    const beta_sc = fmath.sincos(beta);
    const Vr = vec.V3{ airspeed * alpha_sc.c * beta_sc.c, airspeed * beta_sc.s, airspeed * alpha_sc.s * beta_sc.c };
    _ = llt.apply(&inst.p, Vr, .{ de, da, dr }, out[0..surf_count]);
    return panel_count;
}

/// varredura das asas em α (loads/sweep.zig): cada α (rad) imposto ao avião configurado, sem hélice e longe do chão;
/// `owners[i]` é o dono do painel i (−1 fica de fora). Escreve a sustentação de cada dono em cada α
/// (`alpha_count` × `owner_count`), a área e a corda média de cada dono, o c_l de cada painel em cada α e a posição y
/// de cada painel. `method`: 0 faixas, 1 linha sustentadora. Devolve o número de painéis
export fn aerosim_wing_sweep(slot: i32, airspeed: f64, method: i32, alphas: [*]const f64, alpha_count: usize, owners: [*]const i32, owner_count: usize, owner_lift: [*]f64, owner_area: [*]f64, owner_chord: [*]f64, section_cl: [*]f64, panel_span: [*]f64, panel_cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const panel_count: usize = @intCast(inst.p.n_surf);
    if (panel_cap < panel_count) return abiCode(error.BadIndex);
    const load_method = std.enums.fromInt(sweep.Method, method) orelse return abiCode(error.BadIndex);
    sweep.sweep(&inst.p, airspeed, alphas[0..alpha_count], owners[0..panel_count], owner_count, load_method, .{
        .owner_lift = owner_lift[0 .. alpha_count * owner_count],
        .owner_area = owner_area[0..owner_count],
        .owner_chord = owner_chord[0..owner_count],
        .section_cl = section_cl[0 .. alpha_count * panel_count],
        .panel_span = panel_span[0..panel_count],
    }) catch |err| return abiCode(err);
    return @intCast(panel_count);
}

/// resumo da varredura das asas (loads/sweep.zig, `summarize`): C_L de cada dono e do conjunto em cada α, C_L máximo
/// e onde o estol começa. Não precisa de simulação configurada
export fn aerosim_wing_sweep_summary(alpha_count: usize, owner_count: usize, panel_count: usize, owner_lift: [*]const f64, owner_area: [*]const f64, dynamic_pressure: f64, section_cl: [*]const f64, panel_owner: [*]const i32, panel_span: [*]const f64, total_cl: [*]f64, owner_cl: [*]f64, out: *types.SweepSummary) i32 {
    const summary = sweep.summarize(owner_lift[0 .. alpha_count * owner_count], owner_area[0..owner_count], dynamic_pressure, section_cl[0 .. alpha_count * panel_count], panel_owner[0..panel_count], panel_span[0..panel_count], total_cl[0..alpha_count], owner_cl[0 .. alpha_count * owner_count]) catch |err| return abiCode(err);
    out.* = .{ .peak = @intCast(summary.peak), .onset_panel = if (summary.onset_panel) |panel| @intCast(panel) else -1, .lift_max = summary.lift_max, .onset_fraction = summary.onset_fraction };
    return 0;
}

/// número de Reynolds ρ V c / μ de uma corda, com μ (Sutherland) na temperatura da atmosfera padrão na `altitude` (m)
export fn aerosim_reynolds(density: f64, airspeed: f64, chord: f64, altitude: f64) f64 {
    return sweep.reynolds(density, airspeed, chord, altitude);
}

/// `aerosim_aero_coeffs_at` com a carga da linha sustentadora (loads/llt.zig, `coeffs`): as forças dos painéis
/// trocadas pelas da linha sustentadora (Phillips e Snyder; Goates e Hunsaker com `llt_joint`, `llt_blend`); a
/// fuselagem, o c_m das seções e os modificadores ficam os da simulação. Só para análise
export fn aerosim_aero_coeffs_llt(slot: i32, airspeed: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, height: f64, thrusts: [*]const f64, torques: [*]const f64, prop_count: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (prop_count != 0 and prop_count != inst.p.n_prop) return abiCode(error.BadIndex);
    const moment_ref = if (ref) |ref_point| vec.v3(ref_point.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const prop_len: usize = @intCast(prop_count);
    const tq: ?[2][]const f64 = if (prop_count > 0) .{ thrusts[0..prop_len], torques[0..prop_len] } else null;
    out.* = llt.coeffs(&inst.p, airspeed, alpha, beta, .{ pr, qr, rr }, moment_ref, .{ de, da, dr }, height, tq);
    return 0;
}

/// hash (FNV-1a 64) do esquema: confere que o texto chegou inteiro e identifica a versão do layout
export fn aerosim_schema_hash() u64 {
    return abi.schema_hash;
}

/// reserva uma simulação (thread-safe); -1 se todas estiverem em uso
export fn aerosim_acquire() i32 {
    for (&used, 0..) |*in_use, i| {
        if (in_use.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            slots[i] = .{};
            return @intCast(i);
        }
    }
    return abiCode(error.NoFreeSlot);
}

/// devolve a simulação reservada por aerosim_acquire
export fn aerosim_release(slot: i32) void {
    if (slot < 0 or slot >= limits.max_instances) return;
    used[@intCast(slot)].store(false, .release);
}

/// ponteiro para os parâmetros da simulação, que o Python preenche; nulo se o slot não vale
export fn aerosim_params(slot: i32) ?*types.Params {
    const inst = get(slot) catch return null;
    return &inst.p;
}

/// volta os parâmetros aos padrões (antes de escrever uma configuração nova)
export fn aerosim_params_reset(slot: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    inst.p = .{};
    inst.configured = false;
    return 0;
}

/// confere os parâmetros e prepara a simulação; erro negativo se a configuração não vale
export fn aerosim_configure(slot: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.configure(inst) catch |err| return abiCode(err);
    return 0;
}

/// põe o avião parado na pista, no início da missão
export fn aerosim_reset_ground(slot: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.resetGround(inst) catch |err| return abiCode(err);
    return 0;
}

/// põe o avião em voo trimado no começo do segmento `seg`
export fn aerosim_reset_air(slot: i32, seg: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.resetAir(inst, seg) catch |err| return abiCode(err);
    return 0;
}

/// avança até parar, até t_limit ou até encher o buffer; devolve runner.Status
export fn aerosim_run(slot: i32, t_limit: f64, buf: ?[*]types.LogRow, cap: usize, nrows: *usize) i32 {
    nrows.* = 0;
    const inst = get(slot) catch |err| return abiCode(err);
    const log: []types.LogRow = if (buf) |rows_buf| rows_buf[0..cap] else &[_]types.LogRow{};
    return @intFromEnum(runner.run(inst, t_limit, log, nrows));
}

/// eventos registrados na última corrida (decolagem, pouso, ...); nulo se o slot não vale
export fn aerosim_events(slot: i32) ?*const types.Events {
    const inst = get(slot) catch return null;
    return &inst.r.ev;
}

/// tempo atual da simulação (s); -1 se o slot não vale
export fn aerosim_time(slot: i32) f64 {
    const inst = get(slot) catch return -1;
    return inst.r.t;
}

/// tamanho em bytes do estado salvo por aerosim_snapshot_save
export fn aerosim_snapshot_size() usize {
    return @sizeOf(state.Run);
}

/// copia o estado da simulação para `buf` (aerosim_snapshot_size bytes)
export fn aerosim_snapshot_save(slot: i32, buf: [*]u8) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    @memcpy(buf[0..@sizeOf(state.Run)], std.mem.asBytes(&inst.r));
    return 0;
}

/// restaura o estado salvo em `buf`
export fn aerosim_snapshot_load(slot: i32, buf: [*]const u8) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    @memcpy(std.mem.asBytes(&inst.r), buf[0..@sizeOf(state.Run)]);
    return 0;
}

/// massa, CG, inércia e líquido nos tanques do avião configurado
export fn aerosim_mass_props(slot: i32, out: *types.MassProps) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const zero_state = [_]f64{0} ** state.nx;
    const ms = mass.compute(inst.ctx(), &zero_state);
    out.* = .{ .m = ms.m, .cg = vec.arr(ms.rcg) };
    inline for (0..3) |i| inline for (0..3) |j| {
        out.I[3 * i + j] = ms.I[i][j];
    };
    for (inst.p.tank[0..@intCast(inst.p.n_tank)]) |*tank| out.m_liq += tank.m_liq;
    return 0;
}

/// coeficientes aerodinâmicos sem rotação, momentos no CG
export fn aerosim_aero_coeffs(slot: i32, airspeed: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const tc = trim.Ctx.init(&inst.p, &inst.r.f);
    out.* = aero.coeffs(&inst.p, airspeed, alpha, beta, tc.rcg, .{ de, da, dr });
    return 0;
}

/// com rotação (p, q, r em rad/s) e momentos no ponto ref (corpo); ref nulo: CG
export fn aerosim_aero_coeffs_ex(slot: i32, airspeed: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const moment_ref = if (ref) |ref_point| vec.v3(ref_point.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    out.* = aero.coeffsEx(&inst.p, airspeed, alpha, beta, .{ pr, qr, rr }, moment_ref, .{ de, da, dr });
    return 0;
}

/// trima nivelado em V e devolve o modelo linear A, B (ver sim/linear.zig); -4 se a trimagem falhar
export fn aerosim_linearize(slot: i32, airspeed: f64, out: *linear.LinModel) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = linear.linearize(&inst.p, &inst.r.f, airspeed);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

/// ajusta os ganhos do piloto automático pelo modelo linear em V (control/autotune.zig); -4 se a trimagem falhar
export fn aerosim_autotune(slot: i32, airspeed: f64, out: *autotune.Result) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = autotune.tune(&inst.p, &inst.r.f, airspeed);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

/// ponto de operação do motor `prop_index` a `airspeed` com o acelerador `thr`, com o ar no eixo
export fn aerosim_prop_point(slot: i32, prop_index: i32, airspeed: f64, thr: f64, out: *types.PropPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (prop_index < 0 or prop_index >= inst.p.n_prop) return abiCode(error.BadIndex);
    out.* = prop.point(&inst.p, &inst.p.prop[@intCast(prop_index)], airspeed, thr);
    return 0;
}

/// trima no tipo `kind` (nivelado, curva, ...) a `airspeed` com o fator de carga `load_factor`; -4 se falhar
export fn aerosim_trim(slot: i32, kind: i32, airspeed: f64, load_factor: f64, out: *types.TrimPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = trim.solve(trim.Ctx.init(&inst.p, &inst.r.f), kind, airspeed, load_factor, null);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

/// devolve o número de linhas escritas (>= 0) ou erro (< 0)
export fn aerosim_performance(slot: i32, V_hi: f64, V_lo: f64, dV: f64, rows: [*]types.PerfRow, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (!(dV > 0)) return abiCode(error.BadIndex);
    const row_count = trim.performance(trim.Ctx.init(&inst.p, &inst.r.f), V_hi, V_lo, dV, rows[0..cap]);
    return @intCast(row_count);
}

// ---------------------------------------------------------------- envelope por altitude
const envelope = @import("sim/envelope.zig");

/// linhas por altitude (h, ρ, V_min, V_max, V_e, V*, V_cru); devolve quantas (< 0: erro)
export fn aerosim_envelope(slot: i32, cfg: *const envelope.EnvCfg, rows: [*]envelope.EnvRow, cap: usize, ceiling: *f64) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (!(cfg.h_step > 0) or !(cfg.dV > 0) or !(cfg.V_hi > cfg.V_lo)) return abiCode(error.BadIndex);
    return @intCast(envelope.compute(&inst.p, cfg, rows[0..cap], ceiling));
}

/// T_d(V) e T_r(V) numa altitude
export fn aerosim_envelope_curve(slot: i32, cfg: *const envelope.EnvCfg, altitude: f64, airspeeds: [*]f64, Td: [*]f64, Tr: [*]f64, count: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    return @intCast(envelope.curve(&inst.p, cfg, altitude, airspeeds[0..count], Td[0..count], Tr[0..count]));
}

const simple_perf = @import("sim/simple_perf.zig");

/// desempenho por cálculo simples (sem simulação): uma linha por V e o resumo; não usa instância
export fn aerosim_simple_perf(cfg: *const simple_perf.SimpleCfg, rows: [*]simple_perf.SimpleRow, cap: usize, summary: *simple_perf.SimpleSummary) i32 {
    if (!(cfg.dV > 0) or !(cfg.V_hi > cfg.V_lo) or !(cfg.W > 0) or !(cfg.S > 0)) return abiCode(error.BadIndex);
    return @intCast(simple_perf.compute(cfg, rows[0..cap], summary));
}

// ---------------------------------------------------------------- benchmarks
const bench = @import("bench.zig");

/// n chamadas de uma função matemática (ver bench.Kind); devolve a soma (o Python cronometra)
export fn aerosim_bench_math(kind: i32, count: u64, random: i32) f64 {
    const bench_kind = std.enums.fromInt(bench.Kind, kind) orelse return std.math.nan(f64);
    return bench.math(bench_kind, count, random != 0);
}

/// n avaliações da dinâmica f(t, x) no estado atual
export fn aerosim_bench_dynamics(slot: i32, count: u64) f64 {
    const inst = getConfigured(slot) catch return std.math.nan(f64);
    return bench.dynamics(inst, count);
}

/// 1 se compilado com tabelas/polinômios (-Dfast_math=true)
export fn aerosim_fast_math() i32 {
    return if (@import("math/fmath.zig").fast) 1 else 0;
}

// ------------------------------------------------------------------ aeroopt: programa da pontuação
const expr = @import("optim/expr.zig");
const optim_types = @import("optim/types.zig");

/// confere o programa (0 = ok; negativo = `expr.Error`)
export fn aerosim_expr_check(program: *const optim_types.Program) i32 {
    return @intFromEnum(expr.check(program));
}

/// `rows` candidatos: entradas da linha k em `inputs[k * in_stride ..]`, todas as vagas dela em
/// `out[k * out_stride ..]`. Confere o programa antes; erro = código negativo e nada é calculado
export fn aerosim_expr_eval(program: *const optim_types.Program, inputs: [*]const f64, in_stride: usize, rows: usize, out: [*]f64, out_stride: usize) i32 {
    const status = expr.check(program);
    if (status != .ok) return @intFromEnum(status);
    if (in_stride < @as(usize, @intCast(program.n_inputs)) or out_stride < @as(usize, @intCast(program.n_slots))) return @intFromEnum(expr.Error.bad_size);
    if (rows == 0) return 0;
    expr.runMany(program, inputs[0 .. (rows - 1) * in_stride + @as(usize, @intCast(program.n_inputs))], in_stride, rows, out[0 .. (rows - 1) * out_stride + @as(usize, @intCast(program.n_slots))], out_stride);
    return 0;
}

// ------------------------------------------------------------------ corrida rápida da sprint (power.performance)
const ground = @import("sizing/ground.zig");

/// corridas (m) das massas `masses[0..n]` em `out`; inf = não decola
export fn aerosim_ground_runs(ground_run: *const ground.GroundRun, masses: [*]const f64, count: usize, out: [*]f64) i32 {
    for (0..count) |i| out[i] = ground.run(ground_run, masses[i]);
    return 0;
}

/// o maior peso que corre até `runway` (bisseção em [lo, hi]); NaN se nem `lo` decola
export fn aerosim_ground_mtow(ground_run: *const ground.GroundRun, lo: f64, hi: f64, runway: f64) f64 {
    return ground.mtow(ground_run, lo, hi, runway);
}

// ------------------------------------------------------------------ tração motor + hélice da sprint (power.thrust_of)
const motorprop = @import("sizing/motorprop.zig");

/// tração em regime com acelerador cheio em cada `V[0..n]` (densidade `rho`), em `out`
export fn aerosim_motor_prop_thrust(motor_prop: *const motorprop.MotorProp, airspeeds: [*]const f64, count: usize, rho: f64, out: [*]f64) i32 {
    motorprop.curve(motor_prop, airspeeds[0..count], rho, out[0..count]);
    return 0;
}

// ------------------------------------------------------------------ dimensionamento inicial (mini-MDO)
const sizing = @import("sizing/sizing.zig");
const sizing_types = sizing.types;

/// parâmetros de trabalho do dimensionamento, no heap (a struct é grande para a pilha)
fn workParams() ?*types.Params {
    const params = std.heap.page_allocator.create(types.Params) catch return null;
    params.* = .{};
    return params;
}

/// avalia o dimensionamento nas variáveis de projeto `design_vars`
export fn aerosim_sizing_eval(cfg: *const sizing_types.SizingCfg, design_vars: [*]const f64, out: *sizing_types.SizingOut) i32 {
    const params = workParams() orelse return abiCode(error.OutOfMemory);
    defer std.heap.page_allocator.destroy(params);
    out.* = sizing.eval(cfg, params, design_vars[0..sizing_types.n_vars]);
    return 0;
}

/// `progress(ctx, iteração, avaliações no buffer)` ao fim de cada iteração (≠ 0 para parar); pode ser nulo
export fn aerosim_sizing_optimize(cfg: *const sizing_types.SizingCfg, opts: *const sizing_types.OptOpts, buf: [*]sizing_types.Individual, cap: usize, evaluated: *usize, best: *sizing_types.SizingOut, progress: ?*const fn (?*anyopaque, i32, usize) callconv(.c) i32, pctx: ?*anyopaque) i32 {
    const params = workParams() orelse return abiCode(error.OutOfMemory);
    defer std.heap.page_allocator.destroy(params);
    sizing.optimize(cfg, opts, params, buf[0..cap], evaluated, best, progress, pctx);
    return 0;
}

/// nome do item `index` da lista `what` (0: qualidades, 1: variáveis, 2: tipos); nulo se não existe
export fn aerosim_sizing_name(what: i32, index: i32) ?[*:0]const u8 {
    return sizing.name(what, index);
}

/// os padrões do núcleo (as structs ctypes do Python nascem zeradas)
export fn aerosim_sizing_defaults(cfg: *sizing_types.SizingCfg, opts: *sizing_types.OptOpts) void {
    cfg.* = .{};
    opts.* = .{};
}

// ------------------------------------------------------------------ geometria do avião montado
const geometry = @import("geometry/geometry.zig");

/// confere `count` cenas (hélice × peças, massas fora, pedaços soltos, chão); devolve quantas passaram
export fn aerosim_geometry_check(scenes: [*]const geometry.Scene, count: usize, out: [*]geometry.Report) i32 {
    geometry.checkMany(scenes[0..count], out[0..count]);
    var ok: i32 = 0;
    for (out[0..count]) |report| ok += report.ok;
    return ok;
}

// ------------------------------------------------------------------ gerações do aeroopt (algoritmo genético)
const genetic = @import("optim/ga.zig");

/// a primeira geração (pop × n_genes em `out`)
export fn aerosim_ga_init(cfg: *const genetic.GaCfg, out: [*]f64) i32 {
    if (cfg.n_genes < 1 or cfg.n_genes > genetic.max_genes or cfg.pop < 1 or cfg.pop > genetic.max_pop) return abiCode(error.OutOfRange);
    genetic.init(cfg, out[0..@intCast(cfg.pop * cfg.n_genes)]);
    return 0;
}

/// a geração seguinte a partir da nota de cada indivíduo (NaN: morreu)
export fn aerosim_ga_next(cfg: *const genetic.GaCfg, genes: [*]const f64, fit: [*]const f64, out: [*]f64) i32 {
    if (cfg.n_genes < 1 or cfg.n_genes > genetic.max_genes or cfg.pop < 1 or cfg.pop > genetic.max_pop) return abiCode(error.OutOfRange);
    const gene_len: usize = @intCast(cfg.pop * cfg.n_genes);
    genetic.next(cfg, genes[0..gene_len], fit[0..@intCast(cfg.pop)], out[0..gene_len]);
    return 0;
}

// ------------------------------------------------------------------ CMA-ES do aeroopt (variáveis contínuas)
const cmaes = @import("optim/cmaes.zig");

/// prepara o estado do CMA-ES: `x0` normalizado em [0, 1], passo `sigma0`, λ (≤ 0: o padrão 4 + ⌊3 ln n⌋)
export fn aerosim_cma_init(cma_state: *cmaes.CmaState, dims: i32, x0: [*]const f64, sigma0: f64, lambda: i32, seed: i32) i32 {
    if (dims < 1 or dims > cmaes.max_n or lambda > cmaes.max_lambda or !(sigma0 > 0)) return abiCode(error.OutOfRange);
    cmaes.init(cma_state, @intCast(dims), x0[0..@intCast(dims)], sigma0, lambda, seed);
    return cma_state.lambda;
}

/// a geração seguinte: λ × n pontos em `out`, todos em [0, 1]
export fn aerosim_cma_ask(cma_state: *const cmaes.CmaState, out: [*]f64) i32 {
    if (cma_state.n < 1 or cma_state.n > cmaes.max_n or cma_state.lambda < 1 or cma_state.lambda > cmaes.max_lambda) return abiCode(error.OutOfRange);
    cmaes.ask(cma_state, out[0..@intCast(cma_state.lambda * cma_state.n)]);
    return 0;
}

/// a nota de cada ponto da geração (maior é melhor; NaN é o pior) atualiza média, C e σ
export fn aerosim_cma_tell(cma_state: *cmaes.CmaState, xs: [*]const f64, fit: [*]const f64) i32 {
    if (cma_state.n < 1 or cma_state.n > cmaes.max_n or cma_state.lambda < 1 or cma_state.lambda > cmaes.max_lambda) return abiCode(error.OutOfRange);
    cmaes.tell(cma_state, xs[0..@intCast(cma_state.lambda * cma_state.n)], fit[0..@intCast(cma_state.lambda)]);
    return 0;
}

// ------------------------------------------------------------------ evolução diferencial do aeroopt (contínuas)
const diff_evolution = @import("optim/de.zig");

/// a população inicial da evolução diferencial: `x0` na primeira linha, as outras sorteadas em [0, 1] (np × n)
export fn aerosim_de_init(dims: usize, pop_size: usize, x0: [*]const f64, seed: u64, out: [*]f64) i32 {
    if (dims == 0 or dims > diff_evolution.max_n or pop_size > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return if (diff_evolution.initPop(dims, pop_size, x0[0..dims], seed, out[0 .. pop_size * dims])) 0 else abiCode(error.OutOfRange);
}

/// os testes da geração (DE/rand/1/bin, F e CR): um por indivíduo, em [0, 1] (np × n)
export fn aerosim_de_trials(dims: usize, pop_size: usize, pop: [*]const f64, weight: f64, cr: f64, seed: u64, generation: u64, out: [*]f64) i32 {
    if (dims == 0 or dims > diff_evolution.max_n or pop_size > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return if (diff_evolution.trials(dims, pop_size, pop[0 .. pop_size * dims], weight, cr, seed, generation, out[0 .. pop_size * dims])) 0 else abiCode(error.OutOfRange);
}

/// a seleção: o teste que não é pior entra no lugar (muda `pop` e `fit`); devolve quantos entraram
export fn aerosim_de_select(dims: usize, pop_size: usize, pop: [*]f64, fit: [*]f64, trial: [*]const f64, tfit: [*]const f64) i32 {
    if (dims == 0 or dims > diff_evolution.max_n or pop_size < 4 or pop_size > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return @intCast(diff_evolution.select(dims, pop_size, pop[0 .. pop_size * dims], fit[0..pop_size], trial[0 .. pop_size * dims], tfit[0..pop_size]));
}

// ------------------------------------------------------------------ modelo local (sensibilidade do melhor)
const localfit = @import("optim/localfit.zig");

/// y ≈ a + gᵀ(x − x₀) (+ ½ Σ cₖ(xₖ − x₀ₖ)² com `quad` ≠ 0) pelos `points` pontos `xs` (points × dims), com peso (1 − (d/radius)³)³; g em
/// `gradient`, c em `curvature` e `out` = (a, resíduo, soma dos pesos). −1 se as direções não ficam todas determinadas
export fn aerosim_local_fit(dims: usize, points: usize, xs: [*]const f64, ys: [*]const f64, x0: [*]const f64, radius: f64, quad: i32, gradient: [*]f64, curvature: [*]f64, out: [*]f64) i32 {
    if (dims == 0 or dims > localfit.max_n) return abiCode(error.OutOfRange);
    const fit_result = localfit.fit(dims, points, xs[0 .. points * dims], ys[0..points], x0[0..dims], radius, quad != 0, gradient[0..dims], curvature[0..dims]) orelse return abiCode(error.SingularSystem);
    out[0] = fit_result.intercept;
    out[1] = fit_result.rms;
    out[2] = fit_result.weight;
    return 0;
}

// ------------------------------------------------------------------ substituto RBF (GA com substituto)
const rbf = @import("optim/rbf.zig");

/// ajusta s(x) = Σ λᵢ ‖x − xᵢ‖³ + c₀ + cᵀx pelos `points` pontos `xs` (points × dims) com valores `ys`; `coef` recebe
/// (λ₁..λₘ, c₀, c₁..cₙ) e `work` tem (points + dims + 1)² valores. −1 se os pontos não determinam a cauda
export fn aerosim_rbf_fit(dims: usize, points: usize, xs: [*]const f64, ys: [*]const f64, work: [*]f64, coef: [*]f64) i32 {
    if (dims == 0 or dims > rbf.max_n or points < dims + 1) return abiCode(error.OutOfRange);
    const coef_len = rbf.size(dims, points);
    return if (rbf.fit(dims, points, xs[0 .. points * dims], ys[0..points], work[0 .. coef_len * coef_len], coef[0..coef_len])) 0 else abiCode(error.SingularSystem);
}

/// o substituto de `aerosim_rbf_fit` nos `query_count` pontos `queries` (query_count × dims), em `out`
export fn aerosim_rbf_eval(dims: usize, points: usize, xs: [*]const f64, coef: [*]const f64, query_count: usize, queries: [*]const f64, out: [*]f64) void {
    const coef_len = rbf.size(dims, points);
    for (0..query_count) |i| out[i] = rbf.eval(dims, points, xs[0 .. points * dims], coef[0..coef_len], queries[i * dims ..][0..dims]);
}

// ------------------------------------------------------------------ amostragem (hipercubo latino)
const sampling = @import("optim/sampling.zig");

/// `points` pontos em [0, 1]^dims por hipercubo latino; com `tries` > 1, o de maior distância mínima entre tantos sorteios
/// (points × dims em `out`); −1 se não cabe
export fn aerosim_lhs(dims: usize, points: usize, tries: usize, seed: u64, out: [*]f64) i32 {
    if (dims == 0 or dims > sampling.max_n or points == 0 or points > sampling.max_m) return abiCode(error.OutOfRange);
    return if (sampling.lhs(dims, points, tries, seed, out[0 .. points * dims])) 0 else abiCode(error.OutOfRange);
}

// ------------------------------------------------------------------ busca guiada pela falha (reparo, ε, bandido, crenças, LEM)
const guided = @import("optim/guided.zig");

/// o passo de reparo Δx = −Jᵀ (J Jᵀ + λ I)⁻¹ g nas `dims` variáveis do remédio (`jacobian` J: constraints × dims por linhas; `violations` g); −1 se não cabe
/// ou o sistema é singular
export fn aerosim_repair_step(dims: usize, constraints: usize, jacobian: [*]const f64, violations: [*]const f64, lambda: f64, out: [*]f64) i32 {
    if (dims == 0 or dims > guided.max_n or constraints == 0 or constraints > guided.max_m) return abiCode(error.OutOfRange);
    return if (guided.repairStep(dims, constraints, jacobian[0 .. constraints * dims], violations[0..constraints], lambda, out[0..dims])) 0 else abiCode(error.SingularSystem);
}

/// o nível ε(t) = ε₀ (1 − t/Tc)^cp do ε-restrito
export fn aerosim_eps_level(eps0: f64, generation: f64, tc: f64, cp: f64) f64 {
    return guided.epsLevel(eps0, generation, tc, cp);
}

/// 1 se (fa, va) é pior que (fb, vb) na ordem ε, 0 senão
export fn aerosim_eps_worse(fa: f64, va: f64, fb: f64, vb: f64, eps: f64) i32 {
    return if (guided.epsWorse(fa, va, fb, vb, eps)) 1 else 0;
}

/// o tamanho do estado do bandido (f64)
export fn aerosim_bandit_state_len() usize {
    return guided.state_len;
}

/// zera o bandido de `arms` braços em `bandit_state` (aerosim_bandit_state_len f64); −1 se não cabe
export fn aerosim_bandit_init(bandit_state: [*]f64, arms: usize) i32 {
    return if (guided.banditInit(bandit_state[0..guided.state_len], arms)) 0 else abiCode(error.OutOfRange);
}

/// o braço a jogar entre os permitidos (bit k = braço k), UCB1 com o peso `explore_weight`; −1 se nenhum é permitido
export fn aerosim_bandit_pick(bandit_state: [*]const f64, explore_weight: f64, allowed: u32) i32 {
    return guided.banditPick(bandit_state[0..guided.state_len], explore_weight, allowed);
}

/// registra a recompensa do braço `arm`; 1 se o Page–Hinkley (δ, γ) reiniciou o bandido
export fn aerosim_bandit_update(bandit_state: [*]f64, arm: usize, reward: f64, delta: f64, gamma: f64) i32 {
    return if (guided.banditUpdate(bandit_state[0..guided.state_len], arm, reward, delta, gamma)) 1 else 0;
}

/// o espaço normativo (a faixa de cada variável entre os `frac` melhores de `pop`, m × n); −1 se não cabe
export fn aerosim_normative(dims: usize, pop_count: usize, pop: [*]const f64, fit: [*]const f64, frac: f64, lo: [*]f64, hi: [*]f64) i32 {
    if (dims == 0 or dims > guided.max_n or pop_count == 0 or pop_count > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.normative(dims, pop_count, pop[0 .. pop_count * dims], fit[0..pop_count], frac, lo[0..dims], hi[0..dims])) 0 else abiCode(error.OutOfRange);
}

/// a regra do LEM (a faixa que cobre os `frac` melhores e deixa os piores de fora); −1 se não cabe
export fn aerosim_lem_box(dims: usize, pop_count: usize, pop: [*]const f64, fit: [*]const f64, frac: f64, lo: [*]f64, hi: [*]f64) i32 {
    if (dims == 0 or dims > guided.max_n or pop_count < 2 or pop_count > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.lemBox(dims, pop_count, pop[0 .. pop_count * dims], fit[0..pop_count], frac, lo[0..dims], hi[0..dims])) 0 else abiCode(error.OutOfRange);
}

/// `count` pontos uniformes na caixa [lo, hi] (count × n em `out`); −1 se não cabe
export fn aerosim_box_sample(dims: usize, lo: [*]const f64, hi: [*]const f64, count: usize, seed: u64, generation: u64, out: [*]f64) i32 {
    if (dims == 0 or dims > guided.max_n or count > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.boxSample(dims, lo[0..dims], hi[0..dims], count, seed, generation, out[0 .. count * dims])) 0 else abiCode(error.OutOfRange);
}

// ------------------------------------------------------------------ métodos da sensibilidade (tolerância, Morris)
const sensmethods = @import("optim/sensmethods.zig");

/// a perda de nota por tolerância δ em cada uma das `dims` variáveis, com a inclinação `gradient` e a curvatura `curvature` (NaN = sem):
/// ΔN de cada lado em `minus`/`plus`, a elasticidade em `elast`; devolve σ_N (−1 se dims não cabe)
export fn aerosim_sens_tolerance(dims: usize, gradient: [*]const f64, curvature: [*]const f64, x0: [*]const f64, n0: f64, delta: [*]const f64, minus: [*]f64, plus: [*]f64, elast: [*]f64) f64 {
    if (dims == 0 or dims > sensmethods.max_k) return -1;
    return sensmethods.tolerance(dims, gradient[0..dims], curvature[0..dims], x0[0..dims], n0, delta[0..dims], minus[0..dims], plus[0..dims], elast[0..dims]);
}

/// as `trajectories` trajetórias de Morris em [0, 1]^dims numa grade de `levels` níveis: trajectories·(dims + 1)·dims números em `out`; −1 se não cabe
export fn aerosim_morris_design(dims: usize, trajectories: usize, levels: usize, seed: u64, out: [*]f64) i32 {
    if (dims == 0 or dims > sensmethods.max_k or trajectories == 0 or trajectories > sensmethods.max_r) return abiCode(error.OutOfRange);
    return if (sensmethods.morrisDesign(dims, trajectories, levels, seed, out[0 .. trajectories * (dims + 1) * dims])) 0 else abiCode(error.OutOfRange);
}

/// os efeitos elementares (μ, μ*, σ, passos que contaram) das trajetórias `design` com as respostas `responses` (NaN = não vale)
export fn aerosim_morris_effects(dims: usize, trajectories: usize, design: [*]const f64, responses: [*]const f64, mu: [*]f64, mustar: [*]f64, sigma: [*]f64, count: [*]usize) i32 {
    if (dims == 0 or dims > sensmethods.max_k or trajectories == 0 or trajectories > sensmethods.max_r) return abiCode(error.OutOfRange);
    sensmethods.morrisEffects(dims, trajectories, design[0 .. trajectories * (dims + 1) * dims], responses[0 .. trajectories * (dims + 1)], mu[0..dims], mustar[0..dims], sigma[0..dims], count[0..dims]);
    return 0;
}
