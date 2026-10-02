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
const prop = @import("physics/propulsion.zig");
const mass = @import("physics/mass.zig");
const vec = @import("math/vec.zig");

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
