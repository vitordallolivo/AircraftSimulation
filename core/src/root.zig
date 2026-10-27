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

export fn aerosim_abi_version() u32 {
    return abi.version;
}

export fn aerosim_schema() [*:0]const u8 {
    return abi.schema.ptr;
}

/// sonda dos modificadores (sem simulação): fator do efeito solo do método `method` a `h` (m), envergadura `b` (m)
export fn aerosim_probe_ground(method: i32, h: f64, b: f64) f64 {
    return modifiers.ground.factor(method, h, b);
}

/// sonda da esteira (sem simulação): um motor de diâmetro D com tração T, torque Q e sentido `sense`, eixo +x,
/// ar a V ao longo do eixo; no ponto (dx, dy, dz) em relação ao cubo (corpo) devolve
/// out = [velocidade axial a mais (m/s, para trás), giro y, giro z (m/s), raio do tubo ali (m)]
export fn aerosim_probe_slipstream(T_: f64, Q: f64, D: f64, V: f64, rho: f64, sense: f64, dx: f64, dy: f64, dz: f64, out: *[4]f64) i32 {
    const s = modifiers.slipstream.at(T_, Q, V, 0.5 * D, rho, sense, .{ 1, 0, 0 }, .{ dx, dy, dz }, true, true);
    out.* = .{ s.axial, s.swirl[1], s.swirl[2], s.R };
    return if (s.inside) 1 else 0;
}

/// coeficientes como `aerosim_aero_coeffs_ex`, com a tração T[i] e o torque Q[i] de cada motor (n valores) para os
/// modificadores (esteira); ref nulo: CG
export fn aerosim_aero_coeffs_thrust(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (n != inst.p.n_prop) return abiCode(error.BadIndex);
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const k: usize = @intCast(n);
    out.* = aero.coeffsEnv(&inst.p, V, alpha, beta, vec.zero, r, .{ de, da, dr }, .{ Tn[0..k], Qn[0..k] });
    return 0;
}

/// coeficientes com as taxas (p, q, r em rad/s), a altura `h` do avião sobre o chão (m; efeito solo) e a tração T[i] e
/// o torque Q[i] de cada motor (n = 0: sem motores; senão n = número de motores) para os modificadores; ref nulo: CG
export fn aerosim_aero_coeffs_at(slot: i32, V: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, h: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (n != 0 and n != inst.p.n_prop) return abiCode(error.BadIndex);
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const k: usize = @intCast(n);
    const tq: ?[2][]const f64 = if (n > 0) .{ Tn[0..k], Qn[0..k] } else null;
    out.* = aero.coeffsAt(&inst.p, V, alpha, beta, .{ pr, qr, rr }, r, .{ de, da, dr }, h, tq);
    return 0;
}

/// colisão (collision/): fração de cada painel dentro do tubo do motor `idx` — o tubo da esteira com tração T a V
/// (contrai), ou, com T ≤ 0, o cilindro do raio da hélice — até `length` m atrás do disco. Escreve até `cap` valores
/// em `out` (grade 4 × 16 por painel); devolve o número de painéis
export fn aerosim_tube_panel_hits(slot: i32, idx: i32, T_: f64, V: f64, length: f64, out: [*]f64, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const u = &inst.p.prop[@intCast(idx)];
    const sh = modifiers.slipstream.shape(T_, V, 0.5 * u.D, inst.p.env.rho);
    const t = sh.tube(vec.v3(u.r), prop.axis(&inst.p, u), length);
    const n: usize = @intCast(inst.p.n_surf);
    for (inst.p.surf[0..@min(n, cap)], 0..) |*s, i| out[i] = collision.stripFraction(t, modifiers.stripOf(s), 4, 16);
    return @intCast(n);
}

/// colisão: quais dos n pontos (x, y, z do corpo, em sequência) estão dentro do tubo do motor `idx` (ver acima);
/// out[i] = 1 dentro, 0 fora; devolve quantos estão dentro
export fn aerosim_tube_point_hits(slot: i32, idx: i32, T_: f64, V: f64, length: f64, pts: [*]const f64, n: usize, out: [*]i32) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const u = &inst.p.prop[@intCast(idx)];
    const sh = modifiers.slipstream.shape(T_, V, 0.5 * u.D, inst.p.env.rho);
    const t = sh.tube(vec.v3(u.r), prop.axis(&inst.p, u), length);
    var k: i32 = 0;
    for (0..n) |i| {
        const inside = t.contains(.{ pts[3 * i], pts[3 * i + 1], pts[3 * i + 2] });
        out[i] = if (inside) 1 else 0;
        if (inside) k += 1;
    }
    return k;
}

/// estado do motor `idx` com o avião a V, α, β (sem rotação): rotação `rps` imposta (> 0) ou, se ≤ 0, a de
/// equilíbrio com o acelerador `thr`. Tração e torque pela hélice (C_T(J), C_P(J)) com o ar no eixo do motor.
/// Com a rotação imposta só a hélice conta: corrente e potência elétrica saem zeradas (o motor não está em
/// equilíbrio). No polinômio de tração a rotação não entra (T do polinômio, Q = 0).
export fn aerosim_prop_state(slot: i32, idx: i32, V: f64, alpha: f64, beta: f64, rps: f64, thr: f64, out: *types.PropPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (idx < 0 or idx >= inst.p.n_prop) return abiCode(error.BadIndex);
    const u = &inst.p.prop[@intCast(idx)];
    const a = fmath.sincos(alpha);
    const b = fmath.sincos(beta);
    const Vr = vec.V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    const eT = prop.axis(&inst.p, u);
    const imposed = rps > 0;
    const n = if (imposed) rps else prop.equilibriumRps(&inst.p, u, Vr, thr);
    const r = prop.unit(&inst.p, u, eT, Vr, vec.zero, n, if (imposed) 1.0 else thr, 0);
    const Vax = vec.dot(Vr, eT);
    const Ps = r.Q * 2.0 * fmath.pi * n;
    out.* = .{ .V = Vax, .rpm = n * 60.0, .J = r.J, .T = r.T, .Q = r.Q, .P_shaft = Ps, .P_elec = if (imposed) 0 else r.P, .I = if (imposed) 0 else r.I, .eta_prop = if (Ps > 1e-6) r.T * Vax / Ps else 0 };
    return 0;
}

/// estado de cada painel a V, α, β (sem rotação, longe do chão), com a tração T[i] e o torque Q[i] de cada motor
/// (n = número de motores; n = 0: sem motores). Escreve até `cap` painéis em `out`; devolve quantos há.
export fn aerosim_panel_states(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, out: [*]types.PanelState, cap: usize) i32 {
    return panelStates(slot, V, alpha, beta, de, da, dr, Tn, Qn, n, out, cap, false);
}

/// `aerosim_panel_states`; `no_pair`: sem a interferência entre asas ligadas (a linha sustentadora vem depois)
fn panelStates(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, out: [*]types.PanelState, cap: usize, no_pair: bool) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (n != 0 and n != inst.p.n_prop) return abiCode(error.BadIndex);
    const a = fmath.sincos(alpha);
    const b = fmath.sincos(beta);
    const Vr = vec.V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    const k: usize = @intCast(n);
    var env = if (n > 0) modifiers.envFrom(&inst.p, Vr, vec.zero, Tn[0..k], Qn[0..k]) else modifiers.Env.none;
    env.no_pair = no_pair;
    const np_: usize = @intCast(inst.p.n_surf);
    const m = @min(cap, np_);
    const rcg = trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    _ = aero.computeTrace(&inst.p, Vr, vec.zero, rcg, 50.0, .{ de, da, dr }, &env, out[0..m]);
    return @intCast(np_);
}

/// `aerosim_panel_states` com a carga da linha sustentadora (loads/llt.zig: ferraduras, Phillips e Snyder 2000) no
/// lugar do C_Lα uniforme de cada painel: a distribuição ao longo da envergadura depende do alongamento e da forma.
/// Só para análise de cargas; a simulação não usa.
export fn aerosim_panel_states_llt(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, out: [*]types.PanelState, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const np_: usize = @intCast(inst.p.n_surf);
    if (cap < np_) return abiCode(error.BadIndex);
    const k = panelStates(slot, V, alpha, beta, de, da, dr, Tn, Qn, n, out, cap, true);
    if (k < 0) return k;
    const a = fmath.sincos(alpha);
    const b = fmath.sincos(beta);
    const Vr = vec.V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    _ = llt.apply(&inst.p, Vr, .{ de, da, dr }, out[0..np_]);
    return k;
}

/// `aerosim_aero_coeffs_at` com a carga da linha sustentadora (loads/llt.zig, `coeffs`): as forças dos painéis
/// trocadas pelas da linha sustentadora (Phillips e Snyder; Goates e Hunsaker com `llt_joint`, `llt_blend`); a
/// fuselagem, o c_m das seções e os modificadores ficam os da simulação. Só para análise
export fn aerosim_aero_coeffs_llt(slot: i32, V: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, h: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (n != 0 and n != inst.p.n_prop) return abiCode(error.BadIndex);
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const k: usize = @intCast(n);
    const tq: ?[2][]const f64 = if (n > 0) .{ Tn[0..k], Qn[0..k] } else null;
    out.* = llt.coeffs(&inst.p, V, alpha, beta, .{ pr, qr, rr }, r, .{ de, da, dr }, h, tq);
    return 0;
}

/// hash (FNV-1a 64) do esquema: confere que o texto chegou inteiro e identifica a versão do layout
export fn aerosim_schema_hash() u64 {
    return abi.schema_hash;
}

/// reserva uma simulação (thread-safe); -1 se todas estiverem em uso
export fn aerosim_acquire() i32 {
    for (&used, 0..) |*u, i| {
        if (u.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            slots[i] = .{};
            return @intCast(i);
        }
    }
    return abiCode(error.NoFreeSlot);
}

export fn aerosim_release(slot: i32) void {
    if (slot < 0 or slot >= limits.max_instances) return;
    used[@intCast(slot)].store(false, .release);
}

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

export fn aerosim_configure(slot: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.configure(inst) catch |err| return abiCode(err);
    return 0;
}

export fn aerosim_reset_ground(slot: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.resetGround(inst) catch |err| return abiCode(err);
    return 0;
}

export fn aerosim_reset_air(slot: i32, seg: i32) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    runner.resetAir(inst, seg) catch |err| return abiCode(err);
    return 0;
}

/// avança até parar, até t_limit ou até encher o buffer; devolve runner.Status
export fn aerosim_run(slot: i32, t_limit: f64, buf: ?[*]types.LogRow, cap: usize, nrows: *usize) i32 {
    nrows.* = 0;
    const inst = get(slot) catch |err| return abiCode(err);
    const log: []types.LogRow = if (buf) |b| b[0..cap] else &[_]types.LogRow{};
    return @intFromEnum(runner.run(inst, t_limit, log, nrows));
}

export fn aerosim_events(slot: i32) ?*const types.Events {
    const inst = get(slot) catch return null;
    return &inst.r.ev;
}

export fn aerosim_time(slot: i32) f64 {
    const inst = get(slot) catch return -1;
    return inst.r.t;
}

export fn aerosim_snapshot_size() usize {
    return @sizeOf(state.Run);
}

export fn aerosim_snapshot_save(slot: i32, buf: [*]u8) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    @memcpy(buf[0..@sizeOf(state.Run)], std.mem.asBytes(&inst.r));
    return 0;
}

export fn aerosim_snapshot_load(slot: i32, buf: [*]const u8) i32 {
    const inst = get(slot) catch |err| return abiCode(err);
    @memcpy(std.mem.asBytes(&inst.r), buf[0..@sizeOf(state.Run)]);
    return 0;
}

export fn aerosim_mass_props(slot: i32, out: *types.MassProps) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const x = [_]f64{0} ** state.nx;
    const ms = mass.compute(inst.ctx(), &x);
    out.* = .{ .m = ms.m, .cg = vec.arr(ms.rcg) };
    inline for (0..3) |i| inline for (0..3) |j| {
        out.I[3 * i + j] = ms.I[i][j];
    };
    for (inst.p.tank[0..@intCast(inst.p.n_tank)]) |*t| out.m_liq += t.m_liq;
    return 0;
}

export fn aerosim_aero_coeffs(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const tc = trim.Ctx.init(&inst.p, &inst.r.f);
    out.* = aero.coeffs(&inst.p, V, alpha, beta, tc.rcg, .{ de, da, dr });
    return 0;
}

/// com rotação (p, q, r em rad/s) e momentos no ponto ref (corpo); ref nulo: CG
export fn aerosim_aero_coeffs_ex(slot: i32, V: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, ref: ?*const [3]f64, out: *types.AeroCoeffs) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    out.* = aero.coeffsEx(&inst.p, V, alpha, beta, .{ pr, qr, rr }, r, .{ de, da, dr });
    return 0;
}

/// trima nivelado em V e devolve o modelo linear A, B (ver sim/linear.zig); -4 se a trimagem falhar
export fn aerosim_linearize(slot: i32, V: f64, out: *linear.LinModel) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = linear.linearize(&inst.p, &inst.r.f, V);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

/// ajusta os ganhos do piloto automático pelo modelo linear em V (control/autotune.zig); -4 se a trimagem falhar
export fn aerosim_autotune(slot: i32, V: f64, out: *autotune.Result) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = autotune.tune(&inst.p, &inst.r.f, V);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

export fn aerosim_prop_point(slot: i32, i: i32, V: f64, thr: f64, out: *types.PropPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (i < 0 or i >= inst.p.n_prop) return abiCode(error.BadIndex);
    out.* = prop.point(&inst.p, &inst.p.prop[@intCast(i)], V, thr);
    return 0;
}

export fn aerosim_trim(slot: i32, kind: i32, V: f64, n: f64, out: *types.TrimPoint) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    out.* = trim.solve(trim.Ctx.init(&inst.p, &inst.r.f), kind, V, n, null);
    return if (out.ok != 0) 0 else abiCode(error.TrimFailed);
}

/// devolve o número de linhas escritas (>= 0) ou erro (< 0)
export fn aerosim_performance(slot: i32, V_hi: f64, V_lo: f64, dV: f64, rows: [*]types.PerfRow, cap: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    if (!(dV > 0)) return abiCode(error.BadIndex);
    const n = trim.performance(trim.Ctx.init(&inst.p, &inst.r.f), V_hi, V_lo, dV, rows[0..cap]);
    return @intCast(n);
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
export fn aerosim_envelope_curve(slot: i32, cfg: *const envelope.EnvCfg, h: f64, V: [*]f64, Td: [*]f64, Tr: [*]f64, n: usize) i32 {
    const inst = getConfigured(slot) catch |err| return abiCode(err);
    return @intCast(envelope.curve(&inst.p, cfg, h, V[0..n], Td[0..n], Tr[0..n]));
}

const simple_perf = @import("sim/simple_perf.zig");

/// desempenho por cálculo simples (sem simulação): uma linha por V e o resumo; não usa instância
export fn aerosim_simple_perf(cfg: *const simple_perf.SimpleCfg, rows: [*]simple_perf.SimpleRow, cap: usize, sum: *simple_perf.SimpleSummary) i32 {
    if (!(cfg.dV > 0) or !(cfg.V_hi > cfg.V_lo) or !(cfg.W > 0) or !(cfg.S > 0)) return abiCode(error.BadIndex);
    return @intCast(simple_perf.compute(cfg, rows[0..cap], sum));
}

// ---------------------------------------------------------------- benchmarks
const bench = @import("bench.zig");

/// n chamadas de uma função matemática (ver bench.Kind); devolve a soma (o Python cronometra)
export fn aerosim_bench_math(kind: i32, n: u64, random: i32) f64 {
    const k = std.enums.fromInt(bench.Kind, kind) orelse return std.math.nan(f64);
    return bench.math(k, n, random != 0);
}

/// n avaliações da dinâmica f(t, x) no estado atual
export fn aerosim_bench_dynamics(slot: i32, n: u64) f64 {
    const inst = getConfigured(slot) catch return std.math.nan(f64);
    return bench.dynamics(inst, n);
}

/// 1 se compilado com tabelas/polinômios (-Dfast_math=true)
export fn aerosim_fast_math() i32 {
    return if (@import("math/fmath.zig").fast) 1 else 0;
}

// ------------------------------------------------------------------ aeroopt: programa da pontuação
const expr = @import("optim/expr.zig");
const optim_types = @import("optim/types.zig");

/// confere o programa (0 = ok; negativo = `expr.Error`)
export fn aerosim_expr_check(p: *const optim_types.Program) i32 {
    return @intFromEnum(expr.check(p));
}

/// `rows` candidatos: entradas da linha k em `inputs[k * in_stride ..]`, todas as vagas dela em
/// `out[k * out_stride ..]`. Confere o programa antes; erro = código negativo e nada é calculado
export fn aerosim_expr_eval(p: *const optim_types.Program, inputs: [*]const f64, in_stride: usize, rows: usize, out: [*]f64, out_stride: usize) i32 {
    const e = expr.check(p);
    if (e != .ok) return @intFromEnum(e);
    if (in_stride < @as(usize, @intCast(p.n_inputs)) or out_stride < @as(usize, @intCast(p.n_slots))) return @intFromEnum(expr.Error.bad_size);
    if (rows == 0) return 0;
    expr.runMany(p, inputs[0 .. (rows - 1) * in_stride + @as(usize, @intCast(p.n_inputs))], in_stride, rows, out[0 .. (rows - 1) * out_stride + @as(usize, @intCast(p.n_slots))], out_stride);
    return 0;
}

// ------------------------------------------------------------------ corrida rápida da sprint (power.performance)
const ground = @import("sizing/ground.zig");

/// corridas (m) das massas `masses[0..n]` em `out`; inf = não decola
export fn aerosim_ground_runs(g: *const ground.GroundRun, masses: [*]const f64, n: usize, out: [*]f64) i32 {
    for (0..n) |i| out[i] = ground.run(g, masses[i]);
    return 0;
}

/// o maior peso que corre até `runway` (bisseção em [lo, hi]); NaN se nem `lo` decola
export fn aerosim_ground_mtow(g: *const ground.GroundRun, lo: f64, hi: f64, runway: f64) f64 {
    return ground.mtow(g, lo, hi, runway);
}

// ------------------------------------------------------------------ tração motor + hélice da sprint (power.thrust_of)
const motorprop = @import("sizing/motorprop.zig");

/// tração em regime com acelerador cheio em cada `V[0..n]` (densidade `rho`), em `out`
export fn aerosim_motor_prop_thrust(m: *const motorprop.MotorProp, V: [*]const f64, n: usize, rho: f64, out: [*]f64) i32 {
    motorprop.curve(m, V[0..n], rho, out[0..n]);
    return 0;
}

// ------------------------------------------------------------------ dimensionamento inicial (mini-MDO)
const sizing = @import("sizing/sizing.zig");
const sizing_types = sizing.types;

fn workParams() ?*types.Params {
    const p = std.heap.page_allocator.create(types.Params) catch return null;
    p.* = .{};
    return p;
}

export fn aerosim_sizing_eval(cfg: *const sizing_types.SizingCfg, x: [*]const f64, out: *sizing_types.SizingOut) i32 {
    const p = workParams() orelse return abiCode(error.OutOfMemory);
    defer std.heap.page_allocator.destroy(p);
    out.* = sizing.eval(cfg, p, x[0..sizing_types.n_vars]);
    return 0;
}

/// `progress(ctx, iteração, avaliações no buffer)` ao fim de cada iteração (≠ 0 para parar); pode ser nulo
export fn aerosim_sizing_optimize(cfg: *const sizing_types.SizingCfg, opts: *const sizing_types.OptOpts, buf: [*]sizing_types.Individual, cap: usize, n: *usize, best: *sizing_types.SizingOut, progress: ?*const fn (?*anyopaque, i32, usize) callconv(.c) i32, pctx: ?*anyopaque) i32 {
    const p = workParams() orelse return abiCode(error.OutOfMemory);
    defer std.heap.page_allocator.destroy(p);
    sizing.optimize(cfg, opts, p, buf[0..cap], n, best, progress, pctx);
    return 0;
}

export fn aerosim_sizing_name(what: i32, i: i32) ?[*:0]const u8 {
    return sizing.name(what, i);
}

/// os padrões do núcleo (as structs ctypes do Python nascem zeradas)
export fn aerosim_sizing_defaults(cfg: *sizing_types.SizingCfg, opts: *sizing_types.OptOpts) void {
    cfg.* = .{};
    opts.* = .{};
}

// ------------------------------------------------------------------ geometria do avião montado
const geometry = @import("geometry/geometry.zig");

/// confere `n` cenas (hélice × peças, massas fora, pedaços soltos, chão); devolve quantas passaram
export fn aerosim_geometry_check(scenes: [*]const geometry.Scene, n: usize, out: [*]geometry.Report) i32 {
    geometry.checkMany(scenes[0..n], out[0..n]);
    var ok: i32 = 0;
    for (out[0..n]) |r| ok += r.ok;
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
    const k: usize = @intCast(cfg.pop * cfg.n_genes);
    genetic.next(cfg, genes[0..k], fit[0..@intCast(cfg.pop)], out[0..k]);
    return 0;
}

// ------------------------------------------------------------------ CMA-ES do aeroopt (variáveis contínuas)
const cmaes = @import("optim/cmaes.zig");

/// prepara o estado do CMA-ES: `x0` normalizado em [0, 1], passo `sigma0`, λ (≤ 0: o padrão 4 + ⌊3 ln n⌋)
export fn aerosim_cma_init(s: *cmaes.CmaState, n: i32, x0: [*]const f64, sigma0: f64, lambda: i32, seed: i32) i32 {
    if (n < 1 or n > cmaes.max_n or lambda > cmaes.max_lambda or !(sigma0 > 0)) return abiCode(error.OutOfRange);
    cmaes.init(s, @intCast(n), x0[0..@intCast(n)], sigma0, lambda, seed);
    return s.lambda;
}

/// a geração seguinte: λ × n pontos em `out`, todos em [0, 1]
export fn aerosim_cma_ask(s: *const cmaes.CmaState, out: [*]f64) i32 {
    if (s.n < 1 or s.n > cmaes.max_n or s.lambda < 1 or s.lambda > cmaes.max_lambda) return abiCode(error.OutOfRange);
    cmaes.ask(s, out[0..@intCast(s.lambda * s.n)]);
    return 0;
}

/// a nota de cada ponto da geração (maior é melhor; NaN é o pior) atualiza média, C e σ
export fn aerosim_cma_tell(s: *cmaes.CmaState, xs: [*]const f64, fit: [*]const f64) i32 {
    if (s.n < 1 or s.n > cmaes.max_n or s.lambda < 1 or s.lambda > cmaes.max_lambda) return abiCode(error.OutOfRange);
    cmaes.tell(s, xs[0..@intCast(s.lambda * s.n)], fit[0..@intCast(s.lambda)]);
    return 0;
}

// ------------------------------------------------------------------ evolução diferencial do aeroopt (contínuas)
const diff_evolution = @import("optim/de.zig");

/// a população inicial da evolução diferencial: `x0` na primeira linha, as outras sorteadas em [0, 1] (np × n)
export fn aerosim_de_init(n: usize, np: usize, x0: [*]const f64, seed: u64, out: [*]f64) i32 {
    if (n == 0 or n > diff_evolution.max_n or np > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return if (diff_evolution.initPop(n, np, x0[0..n], seed, out[0 .. np * n])) 0 else abiCode(error.OutOfRange);
}

/// os testes da geração (DE/rand/1/bin, F e CR): um por indivíduo, em [0, 1] (np × n)
export fn aerosim_de_trials(n: usize, np: usize, pop: [*]const f64, f: f64, cr: f64, seed: u64, generation: u64, out: [*]f64) i32 {
    if (n == 0 or n > diff_evolution.max_n or np > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return if (diff_evolution.trials(n, np, pop[0 .. np * n], f, cr, seed, generation, out[0 .. np * n])) 0 else abiCode(error.OutOfRange);
}

/// a seleção: o teste que não é pior entra no lugar (muda `pop` e `fit`); devolve quantos entraram
export fn aerosim_de_select(n: usize, np: usize, pop: [*]f64, fit: [*]f64, trial: [*]const f64, tfit: [*]const f64) i32 {
    if (n == 0 or n > diff_evolution.max_n or np < 4 or np > diff_evolution.max_np) return abiCode(error.OutOfRange);
    return @intCast(diff_evolution.select(n, np, pop[0 .. np * n], fit[0..np], trial[0 .. np * n], tfit[0..np]));
}

// ------------------------------------------------------------------ modelo local (sensibilidade do melhor)
const localfit = @import("optim/localfit.zig");

/// y ≈ a + gᵀ(x − x₀) (+ ½ Σ cₖ(xₖ − x₀ₖ)² com `quad` ≠ 0) pelos `m` pontos `xs` (m × n), com peso (1 − (d/r)³)³; g em
/// `g[0..n]`, c em `c[0..n]` e `out` = (a, resíduo, soma dos pesos). −1 se as direções não ficam todas determinadas
export fn aerosim_local_fit(n: usize, m: usize, xs: [*]const f64, ys: [*]const f64, x0: [*]const f64, r: f64, quad: i32, g: [*]f64, c: [*]f64, out: [*]f64) i32 {
    if (n == 0 or n > localfit.max_n) return abiCode(error.OutOfRange);
    const f = localfit.fit(n, m, xs[0 .. m * n], ys[0..m], x0[0..n], r, quad != 0, g[0..n], c[0..n]) orelse return abiCode(error.SingularSystem);
    out[0] = f.a;
    out[1] = f.rms;
    out[2] = f.weight;
    return 0;
}

// ------------------------------------------------------------------ substituto RBF (GA com substituto)
const rbf = @import("optim/rbf.zig");

/// ajusta s(x) = Σ λᵢ ‖x − xᵢ‖³ + c₀ + cᵀx pelos `m` pontos `xs` (m × n) com valores `ys`; `coef` recebe
/// (λ₁..λₘ, c₀, c₁..cₙ) e `work` tem (m + n + 1)² valores. −1 se os pontos não determinam a cauda
export fn aerosim_rbf_fit(n: usize, m: usize, xs: [*]const f64, ys: [*]const f64, work: [*]f64, coef: [*]f64) i32 {
    if (n == 0 or n > rbf.max_n or m < n + 1) return abiCode(error.OutOfRange);
    const k = rbf.size(n, m);
    return if (rbf.fit(n, m, xs[0 .. m * n], ys[0..m], work[0 .. k * k], coef[0..k])) 0 else abiCode(error.SingularSystem);
}

/// o substituto de `aerosim_rbf_fit` nos `q` pontos `qs` (q × n), em `out[0..q]`
export fn aerosim_rbf_eval(n: usize, m: usize, xs: [*]const f64, coef: [*]const f64, q: usize, qs: [*]const f64, out: [*]f64) void {
    const k = rbf.size(n, m);
    for (0..q) |i| out[i] = rbf.eval(n, m, xs[0 .. m * n], coef[0..k], qs[i * n ..][0..n]);
}

// ------------------------------------------------------------------ amostragem (hipercubo latino)
const sampling = @import("optim/sampling.zig");

/// `m` pontos em [0, 1]^n por hipercubo latino; com `tries` > 1, o de maior distância mínima entre tantos sorteios
/// (m × n em `out`); −1 se não cabe
export fn aerosim_lhs(n: usize, m: usize, tries: usize, seed: u64, out: [*]f64) i32 {
    if (n == 0 or n > sampling.max_n or m == 0 or m > sampling.max_m) return abiCode(error.OutOfRange);
    return if (sampling.lhs(n, m, tries, seed, out[0 .. m * n])) 0 else abiCode(error.OutOfRange);
}

// ------------------------------------------------------------------ busca guiada pela falha (reparo, ε, bandido, crenças, LEM)
const guided = @import("optim/guided.zig");

/// o passo de reparo Δx = −Jᵀ (J Jᵀ + λ I)⁻¹ g nas `n` variáveis do remédio (`J`: m × n por linhas); −1 se não cabe
/// ou o sistema é singular
export fn aerosim_repair_step(n: usize, m: usize, J: [*]const f64, g: [*]const f64, lambda: f64, out: [*]f64) i32 {
    if (n == 0 or n > guided.max_n or m == 0 or m > guided.max_m) return abiCode(error.OutOfRange);
    return if (guided.repairStep(n, m, J[0 .. m * n], g[0..m], lambda, out[0..n])) 0 else abiCode(error.SingularSystem);
}

/// o nível ε(t) = ε₀ (1 − t/Tc)^cp do ε-restrito
export fn aerosim_eps_level(eps0: f64, t: f64, tc: f64, cp: f64) f64 {
    return guided.epsLevel(eps0, t, tc, cp);
}

/// 1 se (fa, va) é pior que (fb, vb) na ordem ε, 0 senão
export fn aerosim_eps_worse(fa: f64, va: f64, fb: f64, vb: f64, eps: f64) i32 {
    return if (guided.epsWorse(fa, va, fb, vb, eps)) 1 else 0;
}

/// o tamanho do estado do bandido (f64)
export fn aerosim_bandit_state_len() usize {
    return guided.state_len;
}

/// zera o bandido de `k` braços em `s` (aerosim_bandit_state_len f64); −1 se k não cabe
export fn aerosim_bandit_init(s: [*]f64, k: usize) i32 {
    return if (guided.banditInit(s[0..guided.state_len], k)) 0 else abiCode(error.OutOfRange);
}

/// o braço a jogar entre os permitidos (bit k = braço k), UCB1 com o peso `c`; −1 se nenhum é permitido
export fn aerosim_bandit_pick(s: [*]const f64, c: f64, allowed: u32) i32 {
    return guided.banditPick(s[0..guided.state_len], c, allowed);
}

/// registra a recompensa do braço `a`; 1 se o Page–Hinkley (δ, γ) reiniciou o bandido
export fn aerosim_bandit_update(s: [*]f64, a: usize, reward: f64, delta: f64, gamma: f64) i32 {
    return if (guided.banditUpdate(s[0..guided.state_len], a, reward, delta, gamma)) 1 else 0;
}

/// o espaço normativo (a faixa de cada variável entre os `frac` melhores de `pop`, m × n); −1 se não cabe
export fn aerosim_normative(n: usize, m: usize, pop: [*]const f64, fit: [*]const f64, frac: f64, lo: [*]f64, hi: [*]f64) i32 {
    if (n == 0 or n > guided.max_n or m == 0 or m > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.normative(n, m, pop[0 .. m * n], fit[0..m], frac, lo[0..n], hi[0..n])) 0 else abiCode(error.OutOfRange);
}

/// a regra do LEM (a faixa que cobre os `frac` melhores e deixa os piores de fora); −1 se não cabe
export fn aerosim_lem_box(n: usize, m: usize, pop: [*]const f64, fit: [*]const f64, frac: f64, lo: [*]f64, hi: [*]f64) i32 {
    if (n == 0 or n > guided.max_n or m < 2 or m > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.lemBox(n, m, pop[0 .. m * n], fit[0..m], frac, lo[0..n], hi[0..n])) 0 else abiCode(error.OutOfRange);
}

/// `count` pontos uniformes na caixa [lo, hi] (count × n em `out`); −1 se não cabe
export fn aerosim_box_sample(n: usize, lo: [*]const f64, hi: [*]const f64, count: usize, seed: u64, generation: u64, out: [*]f64) i32 {
    if (n == 0 or n > guided.max_n or count > guided.max_pop) return abiCode(error.OutOfRange);
    return if (guided.boxSample(n, lo[0..n], hi[0..n], count, seed, generation, out[0 .. count * n])) 0 else abiCode(error.OutOfRange);
}

// ------------------------------------------------------------------ métodos da sensibilidade (tolerância, Morris)
const sensmethods = @import("optim/sensmethods.zig");

/// a perda de nota por tolerância δ em cada uma das `n` variáveis, com a inclinação `g` e a curvatura `c` (NaN = sem):
/// ΔN de cada lado em `minus`/`plus`, a elasticidade em `elast`; devolve σ_N (−1 se n não cabe)
export fn aerosim_sens_tolerance(n: usize, g: [*]const f64, c: [*]const f64, x0: [*]const f64, n0: f64, delta: [*]const f64, minus: [*]f64, plus: [*]f64, elast: [*]f64) f64 {
    if (n == 0 or n > sensmethods.max_k) return -1;
    return sensmethods.tolerance(n, g[0..n], c[0..n], x0[0..n], n0, delta[0..n], minus[0..n], plus[0..n], elast[0..n]);
}

/// as `r` trajetórias de Morris em [0, 1]^k numa grade de `p` níveis: r·(k + 1)·k números em `out`; −1 se não cabe
export fn aerosim_morris_design(k: usize, r: usize, p: usize, seed: u64, out: [*]f64) i32 {
    if (k == 0 or k > sensmethods.max_k or r == 0 or r > sensmethods.max_r) return abiCode(error.OutOfRange);
    return if (sensmethods.morrisDesign(k, r, p, seed, out[0 .. r * (k + 1) * k])) 0 else abiCode(error.OutOfRange);
}

/// os efeitos elementares (μ, μ*, σ, passos que contaram) das trajetórias `design` com as respostas `y` (NaN = não vale)
export fn aerosim_morris_effects(k: usize, r: usize, design: [*]const f64, y: [*]const f64, mu: [*]f64, mustar: [*]f64, sigma: [*]f64, count: [*]usize) i32 {
    if (k == 0 or k > sensmethods.max_k or r == 0 or r > sensmethods.max_r) return abiCode(error.OutOfRange);
    sensmethods.morrisEffects(k, r, design[0 .. r * (k + 1) * k], y[0 .. r * (k + 1)], mu[0..k], mustar[0..k], sigma[0..k], count[0..k]);
    return 0;
}
