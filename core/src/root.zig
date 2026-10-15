//! Interface C ABI do núcleo (o que o Python chama via ctypes).
//!
//! Memória estática: um conjunto fixo de `max_instances` simulações. O chamador pega
//! uma com `aerosim_acquire`, escreve os parâmetros direto na struct devolvida por
//! `aerosim_params` (layout em `aerosim_schema`), chama `aerosim_configure` e roda.
//! Internamente os erros são error unions do Zig; aqui viram códigos (< 0 = erro):
//!   -1 slot inválido    -2 não configurado    -3 segmento inválido   -4 trim falhou
//!   -10.. erros de configuração (ver `configCode`)
const std = @import("std");
const L = @import("limits.zig");
const T = @import("types.zig");
const S = @import("sim/state.zig");
const abi = @import("abi.zig");
const runner = @import("sim/runner.zig");
const trim = @import("sim/trim.zig");
const aero = @import("physics/aero.zig");
const modifiers = @import("modifiers/mod.zig");
const fm = @import("math/fmath.zig");
const prop = @import("physics/propulsion.zig");
const mass = @import("physics/mass.zig");
const vec = @import("math/vec.zig");
const linear = @import("sim/linear.zig");
const autotune = @import("control/autotune.zig");

var slots: [L.max_instances]runner.Instance = [_]runner.Instance{.{}} ** L.max_instances;
var used: [L.max_instances]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(false)} ** L.max_instances;

pub const E_SLOT: i32 = -1;
pub const E_NOT_CONFIGURED: i32 = -2;
pub const E_BAD_SEGMENT: i32 = -3;
pub const E_TRIM: i32 = -4;
pub const E_BAD_INDEX: i32 = -5;

fn configCode(e: runner.ConfigError) i32 {
    return switch (e) {
        error.TooManySurfaces => -10,
        error.TooManyProps => -11,
        error.TooManyGear => -12,
        error.TooManyTanks => -13,
        error.TooManySegments => -14,
        error.TooManyEvents => -15,
        error.BadTimeStep => -16,
        error.BadMass => -17,
        error.TooManyPropPoints => -18,
    };
}

fn stateCode(e: runner.StateError) i32 {
    return switch (e) {
        error.NotConfigured => E_NOT_CONFIGURED,
        error.BadSegment => E_BAD_SEGMENT,
        error.TrimFailed => E_TRIM,
    };
}

/// slot em uso ou null (o chamador decide o que fazer com o null)
fn get(slot: i32) ?*runner.Instance {
    if (slot < 0 or slot >= L.max_instances) return null;
    const i: usize = @intCast(slot);
    if (!used[i].load(.acquire)) return null;
    return &slots[i];
}

fn getConfigured(slot: i32) ?*runner.Instance {
    const inst = get(slot) orelse return null;
    return if (inst.configured) inst else null;
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
export fn aerosim_aero_coeffs_thrust(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, ref: ?*const [3]f64, out: *T.AeroCoeffs) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    if (n != inst.p.n_prop) return E_BAD_INDEX;
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    const k: usize = @intCast(n);
    out.* = aero.coeffsEnv(&inst.p, V, alpha, beta, vec.zero, r, .{ de, da, dr }, .{ Tn[0..k], Qn[0..k] });
    return 0;
}

/// estado de cada painel a V, α, β (sem rotação, longe do chão), com a tração T[i] e o torque Q[i] de cada motor
/// (n = número de motores; n = 0: sem motores). Escreve até `cap` painéis em `out`; devolve quantos há.
export fn aerosim_panel_states(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, Tn: [*]const f64, Qn: [*]const f64, n: i32, out: [*]T.PanelState, cap: usize) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    if (n != 0 and n != inst.p.n_prop) return E_BAD_INDEX;
    const a = fm.sincos(alpha);
    const b = fm.sincos(beta);
    const Vr = vec.V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    const k: usize = @intCast(n);
    const env = if (n > 0) modifiers.envFrom(&inst.p, Vr, vec.zero, Tn[0..k], Qn[0..k]) else modifiers.Env.none;
    const np_: usize = @intCast(inst.p.n_surf);
    const m = @min(cap, np_);
    const rcg = trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    _ = aero.computeTrace(&inst.p, Vr, vec.zero, rcg, 50.0, .{ de, da, dr }, &env, out[0..m]);
    return @intCast(np_);
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
    return E_SLOT;
}

export fn aerosim_release(slot: i32) void {
    if (slot < 0 or slot >= L.max_instances) return;
    used[@intCast(slot)].store(false, .release);
}

export fn aerosim_params(slot: i32) ?*T.Params {
    const inst = get(slot) orelse return null;
    return &inst.p;
}

/// volta os parâmetros aos padrões (antes de escrever uma configuração nova)
export fn aerosim_params_reset(slot: i32) i32 {
    const inst = get(slot) orelse return E_SLOT;
    inst.p = .{};
    inst.configured = false;
    return 0;
}

export fn aerosim_configure(slot: i32) i32 {
    const inst = get(slot) orelse return E_SLOT;
    runner.configure(inst) catch |e| return configCode(e);
    return 0;
}

export fn aerosim_reset_ground(slot: i32) i32 {
    const inst = get(slot) orelse return E_SLOT;
    runner.resetGround(inst) catch |e| return stateCode(e);
    return 0;
}

export fn aerosim_reset_air(slot: i32, seg: i32) i32 {
    const inst = get(slot) orelse return E_SLOT;
    runner.resetAir(inst, seg) catch |e| return stateCode(e);
    return 0;
}

/// avança até parar, até t_limit ou até encher o buffer; devolve runner.Status
export fn aerosim_run(slot: i32, t_limit: f64, buf: ?[*]T.LogRow, cap: usize, nrows: *usize) i32 {
    nrows.* = 0;
    const inst = get(slot) orelse return E_SLOT;
    const log: []T.LogRow = if (buf) |b| b[0..cap] else &[_]T.LogRow{};
    return @intFromEnum(runner.run(inst, t_limit, log, nrows));
}

export fn aerosim_events(slot: i32) ?*const T.Events {
    const inst = get(slot) orelse return null;
    return &inst.r.ev;
}

export fn aerosim_time(slot: i32) f64 {
    const inst = get(slot) orelse return -1;
    return inst.r.t;
}

export fn aerosim_snapshot_size() usize {
    return @sizeOf(S.Run);
}

export fn aerosim_snapshot_save(slot: i32, buf: [*]u8) i32 {
    const inst = get(slot) orelse return E_SLOT;
    @memcpy(buf[0..@sizeOf(S.Run)], std.mem.asBytes(&inst.r));
    return 0;
}

export fn aerosim_snapshot_load(slot: i32, buf: [*]const u8) i32 {
    const inst = get(slot) orelse return E_SLOT;
    @memcpy(std.mem.asBytes(&inst.r), buf[0..@sizeOf(S.Run)]);
    return 0;
}

export fn aerosim_mass_props(slot: i32, out: *T.MassProps) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    const x = [_]f64{0} ** S.nx;
    const ms = mass.compute(inst.ctx(), &x);
    out.* = .{ .m = ms.m, .cg = vec.arr(ms.rcg) };
    inline for (0..3) |i| inline for (0..3) |j| {
        out.I[3 * i + j] = ms.I[i][j];
    };
    for (inst.p.tank[0..@intCast(inst.p.n_tank)]) |*t| out.m_liq += t.m_liq;
    return 0;
}

export fn aerosim_aero_coeffs(slot: i32, V: f64, alpha: f64, beta: f64, de: f64, da: f64, dr: f64, out: *T.AeroCoeffs) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    const tc = trim.Ctx.init(&inst.p, &inst.r.f);
    out.* = aero.coeffs(&inst.p, V, alpha, beta, tc.rcg, .{ de, da, dr });
    return 0;
}

/// com rotação (p, q, r em rad/s) e momentos no ponto ref (corpo); ref nulo: CG
export fn aerosim_aero_coeffs_ex(slot: i32, V: f64, alpha: f64, beta: f64, pr: f64, qr: f64, rr: f64, de: f64, da: f64, dr: f64, ref: ?*const [3]f64, out: *T.AeroCoeffs) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    const r = if (ref) |x| vec.v3(x.*) else trim.Ctx.init(&inst.p, &inst.r.f).rcg;
    out.* = aero.coeffsEx(&inst.p, V, alpha, beta, .{ pr, qr, rr }, r, .{ de, da, dr });
    return 0;
}

/// trima nivelado em V e devolve o modelo linear A, B (ver sim/linear.zig); -4 se a trimagem falhar
export fn aerosim_linearize(slot: i32, V: f64, out: *linear.LinModel) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    out.* = linear.linearize(&inst.p, &inst.r.f, V);
    return if (out.ok != 0) 0 else E_TRIM;
}

/// ajusta os ganhos do piloto automático pelo modelo linear em V (control/autotune.zig); -4 se a trimagem falhar
export fn aerosim_autotune(slot: i32, V: f64, out: *autotune.Result) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    out.* = autotune.tune(&inst.p, &inst.r.f, V);
    return if (out.ok != 0) 0 else E_TRIM;
}

export fn aerosim_prop_point(slot: i32, i: i32, V: f64, thr: f64, out: *T.PropPoint) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    if (i < 0 or i >= inst.p.n_prop) return E_BAD_INDEX;
    out.* = prop.point(&inst.p, &inst.p.prop[@intCast(i)], V, thr);
    return 0;
}

export fn aerosim_trim(slot: i32, kind: i32, V: f64, n: f64, out: *T.TrimPoint) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    out.* = trim.solve(trim.Ctx.init(&inst.p, &inst.r.f), kind, V, n, null);
    return if (out.ok != 0) 0 else E_TRIM;
}

/// devolve o número de linhas escritas (>= 0) ou erro (< 0)
export fn aerosim_performance(slot: i32, V_hi: f64, V_lo: f64, dV: f64, rows: [*]T.PerfRow, cap: usize) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    if (!(dV > 0)) return E_BAD_INDEX;
    const n = trim.performance(trim.Ctx.init(&inst.p, &inst.r.f), V_hi, V_lo, dV, rows[0..cap]);
    return @intCast(n);
}

// ---------------------------------------------------------------- envelope por altitude
const envelope = @import("sim/envelope.zig");

/// linhas por altitude (h, ρ, V_min, V_max, V_e, V*, V_cru); devolve quantas (< 0: erro)
export fn aerosim_envelope(slot: i32, cfg: *const envelope.EnvCfg, rows: [*]envelope.EnvRow, cap: usize, ceiling: *f64) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    if (!(cfg.h_step > 0) or !(cfg.dV > 0) or !(cfg.V_hi > cfg.V_lo)) return E_BAD_INDEX;
    return @intCast(envelope.compute(&inst.p, cfg, rows[0..cap], ceiling));
}

/// T_d(V) e T_r(V) numa altitude
export fn aerosim_envelope_curve(slot: i32, cfg: *const envelope.EnvCfg, h: f64, V: [*]f64, Td: [*]f64, Tr: [*]f64, n: usize) i32 {
    const inst = getConfigured(slot) orelse return E_NOT_CONFIGURED;
    return @intCast(envelope.curve(&inst.p, cfg, h, V[0..n], Td[0..n], Tr[0..n]));
}

const simple_perf = @import("sim/simple_perf.zig");

/// desempenho por cálculo simples (sem simulação): uma linha por V e o resumo; não usa instância
export fn aerosim_simple_perf(cfg: *const simple_perf.SimpleCfg, rows: [*]simple_perf.SimpleRow, cap: usize, sum: *simple_perf.SimpleSummary) i32 {
    if (!(cfg.dV > 0) or !(cfg.V_hi > cfg.V_lo) or !(cfg.W > 0) or !(cfg.S > 0)) return E_BAD_INDEX;
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
    const inst = getConfigured(slot) orelse return std.math.nan(f64);
    return bench.dynamics(inst, n);
}

/// 1 se compilado com tabelas/polinômios (-Dfast_math=true)
export fn aerosim_fast_math() i32 {
    return if (@import("math/fmath.zig").fast) 1 else 0;
}

test {
    _ = @import("tests_math.zig");
    _ = @import("tests_physics.zig");
    _ = @import("tests_control.zig");
    _ = @import("tests_sim.zig");
}

// ------------------------------------------------------------------ dimensionamento inicial (mini-MDO)
const sizing = @import("sizing/sizing.zig");
const SZ = sizing.types;

fn workParams() ?*T.Params {
    const p = std.heap.page_allocator.create(T.Params) catch return null;
    p.* = .{};
    return p;
}

export fn aerosim_sizing_eval(cfg: *const SZ.SizingCfg, x: [*]const f64, out: *SZ.SizingOut) i32 {
    const p = workParams() orelse return -1;
    defer std.heap.page_allocator.destroy(p);
    out.* = sizing.eval(cfg, p, x[0..SZ.n_vars]);
    return 0;
}

/// `progress(ctx, iteração, avaliações no buffer)` ao fim de cada iteração (≠ 0 para parar); pode ser nulo
export fn aerosim_sizing_optimize(cfg: *const SZ.SizingCfg, opts: *const SZ.OptOpts, buf: [*]SZ.Individual, cap: usize, n: *usize, best: *SZ.SizingOut, progress: ?*const fn (?*anyopaque, i32, usize) callconv(.c) i32, pctx: ?*anyopaque) i32 {
    const p = workParams() orelse return -1;
    defer std.heap.page_allocator.destroy(p);
    sizing.optimize(cfg, opts, p, buf[0..cap], n, best, progress, pctx);
    return 0;
}

export fn aerosim_sizing_name(what: i32, i: i32) ?[*:0]const u8 {
    return sizing.name(what, i);
}

/// os padrões do núcleo (as structs ctypes do Python nascem zeradas)
export fn aerosim_sizing_defaults(cfg: *SZ.SizingCfg, opts: *SZ.OptOpts) void {
    cfg.* = .{};
    opts.* = .{};
}
