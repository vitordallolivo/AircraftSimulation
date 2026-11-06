//! Bancada das técnicas de otimização (tarefa G27): cada técnica roda a conta de hoje do núcleo e a candidata no
//! mesmo caso, em release, e imprime uma linha JSON com o melhor tempo de N rodadas e uma soma do resultado (para
//! conferir que a candidata dá a mesma conta). Quem chama, compara e escreve a tabela é o `tools/tecnicas.py`.
//!
//!   zig build tecnicas -- <técnica> <variante> [rodadas] [repetições fixas]   (ReleaseFast; -Dopt=hint: dica dos ramos)
//!
//! Técnicas e variantes (a primeira de cada uma é a de hoje):
//!   log       aos | soa       o `gust.settled` (lê 7 dos ~70 campos de cada linha do log) contra o mesmo laço em colunas
//!   faixas    hoje | vetor    o `aero.compute` (laço das faixas) contra as mesmas contas em colunas, 4 faixas por vez
//!   voo       hoje            o `runner.run` inteiro (decolagem e percurso); a candidata é o mesmo código com -Dopt=hint
//!   alocacao  pagina | fixo   o `sizing.eval` com o `Params` pedido ao sistema a cada chamada (como no root.zig)
//!                             contra um `FixedBufferAllocator` sobre um buffer estático
const std = @import("std");
const limits = @import("limits.zig");
const types = @import("types.zig");
const vec = @import("math/vec.zig");
const fmath = @import("math/fmath.zig");
const aero = @import("physics/aero.zig");
const ground = @import("modifiers/ground.zig");
const runner = @import("sim/runner.zig");
const gust = @import("sim/gust.zig");
const test_aircraft = @import("sim/tests.zig");
const sizing = @import("sizing/sizing.zig");
const sizing_types = sizing.types;

const V3 = vec.V3;

/// as técnicas que a bancada sabe medir
const Technique = enum { log, faixas, voo, alocacao };

// ------------------------------------------------------------------ medida

/// repetições fixas por rodada (0: calibra); o Callgrind usa um número fixo para contar as instruções de uma chamada
var fixed_repeats: usize = 0;

/// melhor tempo (ns por chamada) de `rounds` rodadas; cada rodada repete `work` o bastante para passar de ~20 ms
fn measure(io: std.Io, comptime work: fn () f64, rounds: usize) struct { ns: f64, sum: f64 } {
    var repeats: usize = 1;
    var sum: f64 = 0;
    if (fixed_repeats > 0) {
        const elapsed = timed(io, work, fixed_repeats, &sum);
        return .{ .ns = elapsed / @as(f64, @floatFromInt(fixed_repeats)), .sum = sum };
    }
    // calibra: dobra as repetições até a rodada passar de 20 ms
    while (true) {
        const elapsed = timed(io, work, repeats, &sum);
        if (elapsed > 20e6 or repeats > 1 << 28) break;
        repeats *= 2;
    }
    var best: f64 = std.math.inf(f64);
    for (0..rounds) |_| best = @min(best, timed(io, work, repeats, &sum));
    return .{ .ns = best / @as(f64, @floatFromInt(repeats)), .sum = sum };
}

/// ns de `repeats` chamadas; a soma vai para `sum` (o `doNotOptimizeAway` impede o compilador de apagar o laço)
fn timed(io: std.Io, comptime work: fn () f64, repeats: usize, sum: *f64) f64 {
    const start = std.Io.Clock.awake.now(io);
    var acc: f64 = 0;
    for (0..repeats) |_| {
        const value = work();
        std.mem.doNotOptimizeAway(value);
        acc = value;
    }
    const stop = std.Io.Clock.awake.now(io);
    sum.* = acc;
    return @floatFromInt(start.durationTo(stop).toNanoseconds());
}

// ------------------------------------------------------------------ log: linhas (AoS) contra colunas (SoA)

const log_rows = 4096;
const log_step = 0.01; // s
var log: [log_rows]types.LogRow = undefined;

/// as colunas que o `settled` lê, separadas do resto da linha
const Columns = struct {
    p: [log_rows]f64 = undefined,
    q: [log_rows]f64 = undefined,
    r: [log_rows]f64 = undefined,
    alpha: [log_rows]f64 = undefined,
    xcg: [log_rows]f64 = undefined,
    slosh_x: [limits.max_tanks][log_rows]f64 = undefined,
    slosh_y: [limits.max_tanks][log_rows]f64 = undefined,
};
var columns: Columns = .{};
const log_tanks = 1;

/// um log parado (o avião já assentou), com um ruído pequeno: o `settled` lê a janela inteira e devolve verdadeiro
fn fillLog() void {
    var seed: u64 = 7;
    for (&log, 0..) |*row, i| {
        row.* = std.mem.zeroes(types.LogRow);
        const noise = small(&seed);
        row.t = @as(f64, @floatFromInt(i)) * log_step;
        row.p = noise * 1e-3;
        row.q = -noise * 1e-3;
        row.r = noise * 5e-4;
        row.alpha = 0.05 + noise * 1e-4;
        row.xcg = 0.12 + noise * 1e-6;
        row.slosh_x[0] = noise * 1e-4;
        row.slosh_y[0] = -noise * 1e-4;
        columns.p[i] = row.p;
        columns.q[i] = row.q;
        columns.r[i] = row.r;
        columns.alpha[i] = row.alpha;
        columns.xcg[i] = row.xcg;
        columns.slosh_x[0][i] = row.slosh_x[0];
        columns.slosh_y[0][i] = row.slosh_y[0];
    }
}

/// número em [-1, 1] de um LCG (o mesmo ruído em toda rodada)
fn small(seed: *u64) f64 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    const draw: f64 = @floatFromInt(seed.* >> 11);
    return draw * (2.0 / 9007199254740992.0) - 1.0;
}

/// o mesmo critério do `gust.settled` (mesmas constantes), lendo as colunas
fn settledColumns(rows: usize, n_tanks: usize) bool {
    const window: usize = @intFromFloat(@ceil(gust.settle_window / log_step));
    if (rows < window + 1) return false;
    const first = rows - window;
    const rate = 0.5 * std.math.pi / 180.0;
    var low_alpha = columns.alpha[first];
    var high_alpha = low_alpha;
    var low_cg = columns.xcg[first];
    var high_cg = low_cg;
    for (first..rows) |i| {
        if (@abs(columns.p[i]) > rate or @abs(columns.q[i]) > rate or @abs(columns.r[i]) > rate) return false;
        low_alpha = @min(low_alpha, columns.alpha[i]);
        high_alpha = @max(high_alpha, columns.alpha[i]);
        low_cg = @min(low_cg, columns.xcg[i]);
        high_cg = @max(high_cg, columns.xcg[i]);
    }
    if (high_alpha - low_alpha > 0.05 * std.math.pi / 180.0 or high_cg - low_cg > 0.05e-3) return false;
    for (0..n_tanks) |tank| {
        var low_x = columns.slosh_x[tank][first];
        var high_x = low_x;
        var low_y = columns.slosh_y[tank][first];
        var high_y = low_y;
        for (first..rows) |i| {
            low_x = @min(low_x, columns.slosh_x[tank][i]);
            high_x = @max(high_x, columns.slosh_x[tank][i]);
            low_y = @min(low_y, columns.slosh_y[tank][i]);
            high_y = @max(high_y, columns.slosh_y[tank][i]);
        }
        if (high_x - low_x > 0.1 * std.math.pi / 180.0 or high_y - low_y > 0.1 * std.math.pi / 180.0) return false;
    }
    return true;
}

/// o log inteiro passa pelo critério de assentado, uma janela por linha do fim (como o laço da rajada pergunta)
fn logRows() f64 {
    var count: f64 = 0;
    var rows: usize = log_rows - 64;
    while (rows <= log_rows) : (rows += 1) {
        if (gust.settled(log[0..rows], log_tanks, log_step)) count += 1;
    }
    return count;
}
fn logColumns() f64 {
    var count: f64 = 0;
    var rows: usize = log_rows - 64;
    while (rows <= log_rows) : (rows += 1) {
        if (settledColumns(rows, log_tanks)) count += 1;
    }
    return count;
}

// ------------------------------------------------------------------ faixas: o laço de hoje contra 4 faixas por vez

var params: types.Params = .{};
const n_angles = 32;

/// o avião dos testes com a asa dividida em mais faixas (uma asa de verdade tem dezenas)
fn stripAircraft(strips_per_half: usize) void {
    test_aircraft.aircraft(&params);
    const wing = params.surf[0];
    const tail = params.surf[4];
    const fin = params.surf[5];
    var count: usize = 0;
    for ([_]f64{ 1, -1 }) |side| {
        for (0..strips_per_half) |k| {
            var strip = wing;
            const eta = (@as(f64, @floatFromInt(k)) + 0.5) / @as(f64, @floatFromInt(strips_per_half));
            strip.r[1] = side * eta * 1.25;
            strip.S = 0.5 / @as(f64, @floatFromInt(strips_per_half));
            strip.side = if (side > 0) 1 else -1;
            if (eta > 0.6) {
                strip.tau = 0.5;
                strip.mix = .{ 0, -side, 0 };
            }
            params.surf[count] = strip;
            count += 1;
        }
    }
    params.surf[count] = tail;
    params.surf[count + 1] = fin;
    params.n_surf = @intCast(count + 2);
    params.n_mod = 0;
    run_instance.p = params;
    runner.configure(&run_instance) catch {};
    params = run_instance.p; // com ex, ey, ez, a0 e o resto que o configure preenche
}

/// velocidade do ar no corpo para o ângulo número `k` da varredura
fn airAt(k: usize) V3 {
    const alpha = -4.0 * std.math.pi / 180.0 + @as(f64, @floatFromInt(k)) * (0.5 * std.math.pi / 180.0);
    return .{ 18.0 * @cos(alpha), 0.4, 18.0 * @sin(alpha) };
}
const body_rates = V3{ 0.05, -0.02, 0.01 };
const deflections = V3{ -0.03, 0.02, 0.0 };

fn stripsToday() f64 {
    var acc: f64 = 0;
    for (0..n_angles) |k| {
        const out = aero.compute(&params, airAt(k), body_rates, .{ 0.1, 0, 0 }, 20.0, deflections);
        acc += out.F[0] + out.F[2] + out.M[1];
    }
    return acc;
}

/// as faixas em colunas, completadas até um múltiplo de 4 com faixas de área nula
const lanes = 4;
const Lane = @Vector(lanes, f64);
const max_blocks = (limits.max_surfaces + lanes - 1) / lanes;
const StripColumns = struct {
    blocks: usize = 0,
    r: [3][max_blocks]Lane = undefined,
    ex: [3][max_blocks]Lane = undefined,
    ey: [3][max_blocks]Lane = undefined,
    ez: [3][max_blocks]Lane = undefined,
    mix: [3][max_blocks]Lane = undefined,
    tau: [max_blocks]Lane = undefined,
    downwash: [max_blocks]Lane = undefined,
    eps0: [max_blocks]Lane = undefined,
    depsda: [max_blocks]Lane = undefined,
    a0: [max_blocks]Lane = undefined,
    CL0: [max_blocks]Lane = undefined,
    CLa: [max_blocks]Lane = undefined,
    CD0: [max_blocks]Lane = undefined,
    induced_k: [max_blocks]Lane = undefined, // 1 / (π e AR)
    qS_k: [max_blocks]Lane = undefined, // ½ ρ η S
    Cmac_c: [max_blocks]Lane = undefined, // c · Cmac
    in_ground: [max_blocks]Lane = undefined, // 1 nas faixas horizontais (o efeito solo vale)
};
var strip_columns: StripColumns = .{};

/// a faixa `i` de uma coluna (a coluna vista como lista de números, sem o agrupamento de 4)
inline fn slot(column: *[max_blocks]Lane, i: usize) *f64 {
    const flat: *[max_blocks * lanes]f64 = @ptrCast(column);
    return &flat[i];
}

fn packStrips() void {
    const n_surf: usize = @intCast(params.n_surf);
    strip_columns.blocks = (n_surf + lanes - 1) / lanes;
    for (0..strip_columns.blocks * lanes) |i| {
        const surface = if (i < n_surf) params.surf[i] else types.Surface{ .AR = 1, .e = 1 };
        inline for (0..3) |axis| {
            slot(&strip_columns.r[axis], i).* = surface.r[axis];
            slot(&strip_columns.ex[axis], i).* = surface.ex[axis];
            slot(&strip_columns.ey[axis], i).* = surface.ey[axis];
            slot(&strip_columns.ez[axis], i).* = surface.ez[axis];
            slot(&strip_columns.mix[axis], i).* = surface.mix[axis];
        }
        slot(&strip_columns.tau, i).* = surface.tau;
        slot(&strip_columns.downwash, i).* = if (surface.downwash != 0) 1 else 0;
        slot(&strip_columns.eps0, i).* = surface.eps0;
        slot(&strip_columns.depsda, i).* = surface.depsda;
        slot(&strip_columns.a0, i).* = surface.a0;
        slot(&strip_columns.CL0, i).* = surface.CL0;
        slot(&strip_columns.CLa, i).* = surface.CLa;
        slot(&strip_columns.CD0, i).* = surface.CD0;
        slot(&strip_columns.induced_k, i).* = 1.0 / (fmath.pi * surface.e * surface.AR);
        slot(&strip_columns.qS_k, i).* = if (i < n_surf) 0.5 * params.env.rho * surface.eta * surface.S else 0;
        slot(&strip_columns.Cmac_c, i).* = surface.c * surface.Cmac;
        slot(&strip_columns.in_ground, i).* = if (surface.vertical == 0) 1 else 0;
    }
}

/// as mesmas contas do laço das faixas do `aero.computeImpl` sem modificadores (F, M e a parte induzida), 4 faixas
/// por vez; o que não vetoriza (atan2, exp e sincos das tabelas) roda faixa a faixa
fn stripsVector(Vr: V3, rates: V3, rcg: V3, height: f64, commands: V3) struct { F: V3, M: V3 } {
    @setFloatMode(fmath.float_mode);
    const splat = struct {
        inline fn of(value: f64) Lane {
            return @splat(value);
        }
    }.of;
    const alfa = fmath.atan2(Vr[2], Vr[0]);
    var force_sum: [3]Lane = .{ splat(0), splat(0), splat(0) };
    var moment_sum: [3]Lane = .{ splat(0), splat(0), splat(0) };
    for (0..strip_columns.blocks) |b| {
        const rx = strip_columns.r[0][b];
        const ry = strip_columns.r[1][b];
        const rz = strip_columns.r[2][b];
        // local = Vr + ω × r
        const lx = splat(Vr[0]) + splat(rates[1]) * rz - splat(rates[2]) * ry;
        const ly = splat(Vr[1]) + splat(rates[2]) * rx - splat(rates[0]) * rz;
        const lz = splat(Vr[2]) + splat(rates[0]) * ry - splat(rates[1]) * rx;
        const ex = .{ strip_columns.ex[0][b], strip_columns.ex[1][b], strip_columns.ex[2][b] };
        const ez = .{ strip_columns.ez[0][b], strip_columns.ez[1][b], strip_columns.ez[2][b] };
        const u_local = lx * ex[0] + ly * ex[1] + lz * ex[2];
        const ww = lx * ez[0] + ly * ez[1] + lz * ez[2];
        const V2 = u_local * u_local + ww * ww;
        const deflection = strip_columns.mix[0][b] * splat(commands[0]) + strip_columns.mix[1][b] * splat(commands[1]) + strip_columns.mix[2][b] * splat(commands[2]);
        // o que só existe em escalar: o ângulo, a mistura do estol e o C_L, faixa a faixa
        var CL: Lane = undefined;
        var CDi: Lane = undefined;
        var CD: Lane = undefined;
        inline for (0..lanes) |lane| {
            var al = fmath.atan2(ww[lane], u_local[lane]);
            if (strip_columns.downwash[b][lane] != 0) al -= strip_columns.eps0[b][lane] + strip_columns.depsda[b][lane] * alfa;
            al += strip_columns.tau[b][lane] * deflection[lane];
            const sg = aero.sigmaStall(al, strip_columns.a0[b][lane], params.Mst);
            const sin_cos = fmath.sincos(al);
            const cl = (1.0 - sg) * (strip_columns.CL0[b][lane] + strip_columns.CLa[b][lane] * al) + sg * 2.0 * fmath.sgn(al) * sin_cos.s * sin_cos.s * sin_cos.c;
            var fge: f64 = 1.0;
            if (strip_columns.in_ground[b][lane] != 0) fge = ground.factor(params.ground, height - strip_columns.r[2][b][lane], params.bref);
            CL[lane] = cl;
            CDi[lane] = (1.0 - sg) * cl * cl * strip_columns.induced_k[b][lane] * fge;
            CD[lane] = strip_columns.CD0[b][lane] + CDi[lane] + sg * 1.2 * sin_cos.s * sin_cos.s;
        }
        const live = V2 >= splat(1e-6);
        const Vp = @sqrt(@select(f64, live, V2, splat(1)));
        const qS = @select(f64, live, strip_columns.qS_k[b] * V2, splat(0));
        // lift_dir = (ex ww − ez u) / Vp ; drag_dir = −(ex u + ez ww) / Vp
        var force: [3]Lane = undefined;
        inline for (0..3) |axis| {
            const lift = (ex[axis] * ww - ez[axis] * u_local) / Vp;
            const drag = -(ex[axis] * u_local + ez[axis] * ww) / Vp;
            force[axis] = lift * qS * CL + drag * qS * CD;
            force_sum[axis] += force[axis];
        }
        // momento = (r − rcg) × F + ey qS c Cmac
        const dx = rx - splat(rcg[0]);
        const dy = ry - splat(rcg[1]);
        const dz = rz - splat(rcg[2]);
        const own = qS * strip_columns.Cmac_c[b];
        moment_sum[0] += dy * force[2] - dz * force[1] + strip_columns.ey[0][b] * own;
        moment_sum[1] += dz * force[0] - dx * force[2] + strip_columns.ey[1][b] * own;
        moment_sum[2] += dx * force[1] - dy * force[0] + strip_columns.ey[2][b] * own;
    }
    return .{
        .F = .{ @reduce(.Add, force_sum[0]), @reduce(.Add, force_sum[1]), @reduce(.Add, force_sum[2]) },
        .M = .{ @reduce(.Add, moment_sum[0]), @reduce(.Add, moment_sum[1]), @reduce(.Add, moment_sum[2]) },
    };
}

/// só as faixas do `aero.compute` (sem a fuselagem), para comparar com o vetorizado
fn stripsOnly(Vr: V3) struct { F: V3, M: V3 } {
    const out = aero.compute(&params, Vr, body_rates, .{ 0.1, 0, 0 }, 20.0, deflections);
    const fuselage = limits.groupIndex(.fuselage);
    return .{ .F = out.F - out.Fg[fuselage], .M = out.M - out.Mg[fuselage] };
}

fn stripsVectorSweep() f64 {
    var acc: f64 = 0;
    for (0..n_angles) |k| {
        const out = stripsVector(airAt(k), body_rates, .{ 0.1, 0, 0 }, 20.0, deflections);
        acc += out.F[0] + out.F[2] + out.M[1];
    }
    return acc;
}
fn stripsTodaySweep() f64 {
    var acc: f64 = 0;
    for (0..n_angles) |k| {
        const out = stripsOnly(airAt(k));
        acc += out.F[0] + out.F[2] + out.M[1];
    }
    return acc;
}

// ------------------------------------------------------------------ voo: o runner.run inteiro

var run_instance: runner.Instance = .{};
var configured: runner.Instance = .{};
var flight_log: [4096]types.LogRow = undefined;

/// configura o avião uma vez (o configure varre o C_L máximo de cada faixa, que não é o laço do voo)
fn flightSetup() void {
    test_aircraft.aircraft(&configured.p);
    configured.p.stop_takeoff = 1;
    runner.configure(&configured) catch {};
}

/// a decolagem inteira, do chão até a altura de fim, a partir do avião já configurado
fn flight() f64 {
    run_instance = configured;
    runner.resetGround(&run_instance) catch return -1;
    var rows: usize = 0;
    _ = runner.run(&run_instance, 60.0, &flight_log, &rows);
    return run_instance.r.t + @as(f64, @floatFromInt(rows));
}

// ------------------------------------------------------------------ alocação: o Params do dimensionamento

var sizing_cfg: sizing_types.SizingCfg = .{};
const design_vars = [_]f64{0} ** sizing_types.n_vars;
var fixed_buffer: [@sizeOf(types.Params) + @alignOf(types.Params)]u8 align(@alignOf(types.Params)) = undefined;

fn sizingCfg() void {
    sizing_cfg = .{};
    sizing_cfg.vars[sizing_types.variable(.span)] = .{ .lo = 2.0, .hi = 2.0 };
    sizing_cfg.vars[sizing_types.variable(.area)] = .{ .lo = 0.8, .hi = 0.8 };
    sizing_cfg.vars[sizing_types.variable(.taper)] = .{ .lo = 0.6, .hi = 0.6 };
    sizing_cfg.vars[sizing_types.variable(.motors)] = .{ .lo = 1, .hi = 1, .kind = .integer };
    sizing_cfg.sets[0].mass = 0.9;
    sizing_cfg.cons[0] = .{ .q = .takeoff_run, .op = .at_most, .value = 40 };
    sizing_cfg.n_cons = 1;
}

/// como o `aerosim_sizing_eval` faz hoje: o Params pedido ao sistema (mmap) e devolvido a cada chamada
fn allocPage() f64 {
    const work = std.heap.page_allocator.create(types.Params) catch return -1;
    defer std.heap.page_allocator.destroy(work);
    work.* = .{};
    return sizing.eval(&sizing_cfg, work, &design_vars).score;
}
/// o mesmo com um FixedBufferAllocator sobre um buffer estático (sem chamar o sistema)
fn allocFixed() f64 {
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const work = fixed.allocator().create(types.Params) catch return -1;
    work.* = .{};
    return sizing.eval(&sizing_cfg, work, &design_vars).score;
}

// ------------------------------------------------------------------ main

/// `tecnicas <técnica> <variante> [rodadas] [repetições fixas]`: imprime {"tecnica", "variante", "ns", "soma"}
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    if (args.len < 3) {
        try out.print("uso: tecnicas <log|faixas|voo|alocacao> <variante> [rodadas]\n", .{});
        try out.flush();
        return;
    }
    const technique = std.meta.stringToEnum(Technique, args[1]) orelse return error.TecnicaDesconhecida;
    const variant = args[2];
    const rounds: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 7;
    if (args.len > 4) fixed_repeats = try std.fmt.parseInt(usize, args[4], 10);
    const result = switch (technique) {
        .log => blk: {
            fillLog();
            if (std.mem.eql(u8, variant, "aos")) break :blk measure(io, logRows, rounds);
            if (std.mem.eql(u8, variant, "soa")) break :blk measure(io, logColumns, rounds);
            return error.VarianteDesconhecida;
        },
        .faixas => blk: {
            stripAircraft(20);
            packStrips();
            if (std.mem.eql(u8, variant, "hoje")) break :blk measure(io, stripsTodaySweep, rounds);
            if (std.mem.eql(u8, variant, "vetor")) break :blk measure(io, stripsVectorSweep, rounds);
            return error.VarianteDesconhecida;
        },
        .voo => blk: {
            flightSetup();
            if (std.mem.eql(u8, variant, "hoje")) break :blk measure(io, flight, rounds);
            return error.VarianteDesconhecida;
        },
        .alocacao => blk: {
            sizingCfg();
            if (std.mem.eql(u8, variant, "pagina")) break :blk measure(io, allocPage, rounds);
            if (std.mem.eql(u8, variant, "fixo")) break :blk measure(io, allocFixed, rounds);
            return error.VarianteDesconhecida;
        },
    };
    try out.print("{{\"tecnica\": \"{s}\", \"variante\": \"{s}\", \"opt\": {d}, \"ns\": {d:.1}, \"soma\": {e}}}\n", .{ args[1], variant, fmath.opt, result.ns, result.sum });
    try out.flush();
}
