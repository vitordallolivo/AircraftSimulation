//! Testes de integração do núcleo: aeronave monomotora convencional (a do código
//! original), decolagem, checkpoint e trimagem.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("state.zig");
const runner = @import("runner.zig");
const trim = @import("trim.zig");

const deg = std.math.rad_per_deg;

fn helmbold(a0: f64, AR: f64) f64 {
    const k = a0 / (std.math.pi * AR);
    return a0 / (@sqrt(1.0 + k * k) + k);
}

fn aircraft(params: *types.Params) void {
    params.* = .{ .m_dry = 8.39, .Ixx = 0.9, .Iyy = 1.2, .Izz = 1.9, .Ixz = 0.04, .Sref = 1.0, .cref = 0.4, .bref = 2.5 };
    params.fus_CDS = 0.03;
    params.fus_Cma = 0.1;
    params.fus_Cnb = -0.03;
    params.fus_CYb = -0.15;
    const ARw = 6.25;
    const CLaw = helmbold(5.9, ARw);
    const wing = types.Surface{ .c = 0.4, .AR = ARw, .e = 0.85, .dihedral = 3 * deg, .incidence = 2 * deg, .CLa = CLaw, .CL0 = 0.3, .CLmax = 1.6, .CD0 = 0.012, .Cmac = -0.08 };
    const yi = 0.6 * 2.5 / 4.0;
    const ye = 1.6 * 2.5 / 4.0;
    params.n_surf = 6;
    params.surf[0] = wing;
    params.surf[0].r = .{ 0.035, yi, -0.12 };
    params.surf[0].S = 0.3;
    params.surf[0].side = 1;
    params.surf[1] = wing;
    params.surf[1].r = .{ 0.035, ye, -0.12 };
    params.surf[1].S = 0.2;
    params.surf[1].side = 1;
    params.surf[1].tau = 0.5;
    params.surf[1].mix = .{ 0, -1, 0 };
    params.surf[2] = params.surf[0];
    params.surf[2].r[1] = -yi;
    params.surf[2].side = -1;
    params.surf[3] = params.surf[1];
    params.surf[3].r[1] = -ye;
    params.surf[3].side = -1;
    params.surf[3].mix = .{ 0, 1, 0 };
    const CLw0 = 0.3 + CLaw * 2 * deg;
    params.surf[4] = .{ .group = limits.group_htail, .r = .{ -1.05, 0, -0.05 }, .S = 0.2, .c = @sqrt(0.2 / 4.0), .AR = 4, .incidence = -2 * deg, .CLa = helmbold(5.9, 4), .CLmax = 1.0, .CD0 = 0.012, .tau = 0.5, .mix = .{ 1, 0, 0 }, .eta = 0.9, .downwash = 1, .eps0 = 2 * CLw0 / (std.math.pi * ARw), .depsda = 2 * CLaw / (std.math.pi * ARw) };
    params.surf[5] = .{ .group = limits.group_vtail, .vertical = 1, .r = .{ -1.1, 0, -0.22 }, .S = 0.12, .c = @sqrt(0.12 / 1.6), .AR = 1.6, .CLa = helmbold(5.9, 1.6), .CLmax = 1.0, .CD0 = 0.012, .tau = 0.5, .mix = .{ 0, 0, -1 }, .eta = 0.9 };
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .r = .{ 0.55, 0, 0 }, .tilt = 3 * deg, .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035 };
    const tab = [_][3]f64{ .{ 0, 0.0896, 0.0299 }, .{ 0.1169, 0.0818, 0.0316 }, .{ 0.2338, 0.0706, 0.032 }, .{ 0.3507, 0.0555, 0.0296 }, .{ 0.4676, 0.0368, 0.0239 }, .{ 0.5846, 0.0162, 0.015 }, .{ 0.6781, 0, 0.0062 } };
    prop_unit.n_pts = tab.len;
    for (tab, 0..) |table_row, i| {
        prop_unit.J[i] = table_row[0];
        prop_unit.CT[i] = table_row[1];
        prop_unit.CP[i] = table_row[2];
    }
    params.n_gear = 4;
    params.gear[0] = .{ .kind = types.gear_steer, .r = .{ 0.45, 0, 0.22 }, .k = 2000, .c = 60 };
    params.gear[1] = .{ .kind = types.gear_main, .r = .{ -0.05, -0.3, 0.22 }, .k = 4000, .c = 120 };
    params.gear[2] = .{ .kind = types.gear_main, .r = .{ -0.05, 0.3, 0.22 }, .k = 4000, .c = 120 };
    params.gear[3] = .{ .kind = types.gear_skid, .r = .{ -1.1, 0, 0 }, .k = 6000, .c = 150 };
    params.n_tank = 1;
    params.tank[0] = .{ .r = .{ 0.1, 0, 0.05 }, .shape = types.tank_cylinder, .side = 0.16, .fill = 0.08 };
    params.payload = .{ .enabled = 1, .m = 2, .r = .{ -0.05, 0, 0.08 }, .bay = 0.35 };
    params.takeoff = .{ .sR = 37.5, .de1 = -3 * deg, .rate_de = 60 * deg };
    params.ap.CL0 = 0.398;
    params.ap.CLa = 4.747;
    params.ap.alpha_max = 11 * deg;
    params.n_seg = 2;
    params.seg[0] = .{ .takeoff = 1, .L = 100, .h0 = 15, .h1 = 15, .V0 = 15, .V1 = 15 };
    params.seg[1] = .{ .n0 = 100, .L = 300, .h0 = 15, .h1 = 15, .V0 = 15, .V1 = 15 };
}

var inst: runner.Instance = .{};
var inst2: runner.Instance = .{};
var log: [4096]types.LogRow = undefined;

test "decolagem até h_end" {
    aircraft(&inst.p);
    inst.p.stop_takeoff = 1;
    try runner.configure(&inst);
    try runner.resetGround(&inst);
    var log_count: usize = 0;
    const st = runner.run(&inst, 1e9, &log, &log_count);
    try std.testing.expectEqual(runner.Status.completed, st);
    const ev = inst.r.ev;
    try std.testing.expect(ev.tLO > 0 and ev.nLO > 20 and ev.nLO < 80);
    try std.testing.expect(log_count > 10);
}

test "proteção de α na decolagem" {
    // com o comando todo cabrando fixo (−25°) o avião passa de alpha_max (uns 32°) até o piloto assumir em ht; com a
    // proteção ligada, para perto dele
    var amax: f64 = 0;
    for ([_]f64{ 0, 1 }) |guard| {
        aircraft(&inst.p);
        inst.p.stop_takeoff = 1;
        inst.p.takeoff.de1 = -25 * deg;
        inst.p.takeoff.alpha_guard = guard;
        try runner.configure(&inst);
        try runner.resetGround(&inst);
        var log_count: usize = 0;
        const st = runner.run(&inst, 1e9, &log, &log_count);
        var top: f64 = 0;
        for (log[0..log_count]) |row| {
            if (row.h >= inst.p.takeoff.ht) break;
            if (row.Va > 5) top = @max(top, row.alpha); // parado, α não tem sentido
        }
        if (guard == 0) {
            amax = top;
            try std.testing.expect(top > inst.p.ap.alpha_max);
        } else {
            try std.testing.expect(top < amax);
            try std.testing.expect(top < inst.p.ap.alpha_max + 2 * deg);
            try std.testing.expectEqual(runner.Status.completed, st); // sem a proteção, estola e não chega a h_end
        }
    }
}

test "proteção de α: o limite é o estol do avião (C_L/C_Lmax = kCL), não o alpha_max fixo" {
    aircraft(&inst.p);
    try runner.configure(&inst);
    const lim = inst.p.alpha_guard_lim;
    try std.testing.expect(lim > 0 and lim < 30 * deg);
    const aeromodel = @import("../physics/aeromodel.zig");
    const mods = @import("../modifiers/mod.zig");
    const vec = @import("../math/vec.zig");
    const ratio = struct {
        fn at(params: *const types.Params, alpha: f64) f64 {
            const Vr = vec.V3{ 12.0 * @cos(alpha), 0, 12.0 * @sin(alpha) };
            return aeromodel.compute(params, Vr, vec.zero, vec.zero, 100.0, vec.zero, &mods.Env.none).ratioCL;
        }
    }.at;
    try std.testing.expect(ratio(&inst.p, lim) >= inst.p.ap.kCL);
    try std.testing.expect(ratio(&inst.p, lim - 0.25 * deg) < inst.p.ap.kCL);
}

test "checkpoint: retomar dá o mesmo resultado" {
    aircraft(&inst.p);
    inst.p.stop_t = 6.0;
    try runner.configure(&inst);
    try runner.resetGround(&inst);
    var log_count: usize = 0;
    try std.testing.expectEqual(runner.Status.stopped, runner.run(&inst, 1e9, &log, &log_count));
    const snap = inst.r;
    inst.p.stop_t = 9.0;
    _ = runner.run(&inst, 1e9, &log, &log_count);
    inst2 = inst;
    inst2.r = snap;
    _ = runner.run(&inst2, 1e9, &log, &log_count);
    try std.testing.expectEqual(inst.r.x[state.index(.north)], inst2.r.x[state.index(.north)]);
}

test "fatias de tempo continuam sem perder passos" {
    aircraft(&inst.p);
    inst.p.stop_t = 4.0;
    try runner.configure(&inst);
    try runner.resetGround(&inst);
    var log_count: usize = 0;
    var st = runner.run(&inst, 1.0, &log, &log_count);
    try std.testing.expectEqual(runner.Status.chunk, st);
    while (st == .chunk) st = runner.run(&inst, inst.r.t + 1.0, &log, &log_count);
    try std.testing.expectEqual(runner.Status.stopped, st);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), inst.r.t, 2e-3);
}

test "trimagem nivelada e começo em voo" {
    aircraft(&inst.p);
    try runner.configure(&inst);
    const tp = trim.solve(trim.Ctx.init(&inst.p, &inst.r.f), types.trim_level, 15, 1, null);
    try std.testing.expect(tp.ok == 1);
    try std.testing.expect(tp.thr > 0 and tp.thr < 1);
    try runner.resetAir(&inst, 1);
    inst.p.stop_t = 5;
    var log_count: usize = 0;
    _ = runner.run(&inst, 1e9, &log, &log_count);
    try std.testing.expectApproxEqAbs(@as(f64, 15), -inst.r.x[state.index(.down)], 1.0);
}

const linear = @import("linear.zig");

test "linearização: equilíbrio, amortecimentos e acoplamentos" {
    aircraft(&inst.p);
    try runner.configure(&inst);
    const lm = linear.linearize(&inst.p, &inst.r.f, 16);
    try std.testing.expect(lm.ok == 1);
    try std.testing.expect(linear.residual(&inst.p, &inst.r.f, &lm) < 1e-4);
    const state_matrix = lm.A;
    const state_count = linear.nl;
    // u v w p q r φ θ
    try std.testing.expect(state_matrix[4 * state_count + 4] < 0); // M_q
    try std.testing.expect(state_matrix[3 * state_count + 3] < 0); // L_p
    try std.testing.expect(state_matrix[5 * state_count + 5] < 0); // N_r
    try std.testing.expect(state_matrix[2 * state_count + 2] < 0); // Z_w
    try std.testing.expect(state_matrix[4 * state_count + 2] < 0); // M_w: estável em arfagem
    try std.testing.expect(state_matrix[5 * state_count + 1] > 0); // N_v: estável em guinada
    // quase simétrico (só δa, δr de equilíbrio do torque acoplam): v ~ não mexe em q, w em p
    try std.testing.expect(@abs(state_matrix[4 * state_count + 1]) < 0.05 * @abs(state_matrix[4 * state_count + 2]));
    try std.testing.expect(@abs(state_matrix[3 * state_count + 2]) < 0.05 * @abs(state_matrix[3 * state_count + 1]));
    try std.testing.expect(lm.B[4 * linear.nu + 0] < 0); // M_δe: δe > 0 baixa o nariz
}

test "avião que não pode voar: erro claro, sem pane" {
    aircraft(&inst.p);
    inst.p.n_gear = 0; // sem trem: cairia na pista
    try runner.configure(&inst); // as análises sem voo continuam aceitando
    try std.testing.expectError(error.NoGear, runner.resetGround(&inst));
    aircraft(&inst.p);
    inst.p.Ixx = 0; // sem inércia de rolamento
    try runner.configure(&inst);
    try std.testing.expectError(error.BadInertia, runner.resetGround(&inst));
    try std.testing.expectError(error.BadInertia, runner.resetAir(&inst, 1));
    inst.p.Ixx = std.math.nan(f64);
    try std.testing.expectError(error.BadInertia, runner.resetGround(&inst));
}

test "linearização com o líquido: sem tanque é a do corpo rígido; o pêndulo tem a frequência de Abramson" {
    aircraft(&inst.p);
    inst.p.n_tank = 0;
    try runner.configure(&inst);
    const rigid_model = linear.linearize(&inst.p, &inst.r.f, 16);
    inst.p.slosh_on = 1;
    const without_tank = linear.linearizeSlosh(&inst.p, &inst.r.f, 16);
    try std.testing.expect(without_tank.ok == 1 and without_tank.n == linear.nl);
    for (0..linear.nl) |i| for (0..linear.nl) |j| {
        const expected = rigid_model.A[i * linear.nl + j];
        try std.testing.expectApproxEqAbs(expected, without_tank.A[i * linear.nl_slosh + j], 1e-6 * @max(@abs(expected), 1.0));
    };
    // um tanque quadrado de 0,12 m com 7 cm de água no CG: o pêndulo equivalente oscila em ω₁ = √(g k tanh(k h)),
    // k = π / lado (Abramson, NASA SP-106, cap. 6), com o amortecimento 2 ζ ω₁ do tanque
    inst.p.n_tank = 1;
    inst.p.tank[0] = .{ .side = 0.12, .fill = 0.07, .rho = 1000, .zeta = 0.03, .r = .{ 0, 0, 0 } };
    try runner.configure(&inst);
    const tank = inst.p.tank[0];
    const wavenumber: f64 = std.math.pi / 0.12;
    try std.testing.expectApproxEqRel(@sqrt(limits.g0 * wavenumber * std.math.tanh(wavenumber * 0.07)), tank.w1, 1e-9);
    const with_tank = linear.linearizeSlosh(&inst.p, &inst.r.f, 16);
    try std.testing.expect(with_tank.ok == 1 and with_tank.n == linear.nl + 4);
    const swing_row = (linear.nl + 2) * linear.nl_slosh; // η̈x
    try std.testing.expectApproxEqRel(-tank.w1 * tank.w1, with_tank.A[swing_row + linear.nl], 0.05); // ∂η̈x/∂ηx
    try std.testing.expectApproxEqRel(-2 * tank.zeta * tank.w1, with_tank.A[swing_row + linear.nl + 2], 0.05); // ∂η̈x/∂η̇x
    inst.p.slosh_on = 0;
    inst.p.n_tank = 0;
}

const gust = @import("gust.zig");

test "rajada vertical em manche fixo: α sobe perto de U/V e volta; sem rajada fica no equilíbrio; o líquido balança só livre" {
    // α = atan(w/u): uma rajada vertical U soma no máximo atan(U/V) ao ângulo de ataque (definição de α, Etkin e
    // Reid, cap. 4); com a 1 − cos de 1 s o avião já arfa junto, então o pico fica abaixo disso
    aircraft(&inst.p);
    const quiet = try gust.respond(&inst, .{ .vertical = 0, .span = 6 }, &log);
    const alpha_trim = log[0].alpha;
    for (log[0..quiet]) |row| {
        try std.testing.expectApproxEqAbs(alpha_trim, row.alpha, 0.2 * deg);
        try std.testing.expectApproxEqAbs(log[0].slosh_x[0], row.slosh_x[0], 0.2 * deg); // o líquido sai parado (só segue a arfagem lenta)
    }

    aircraft(&inst.p);
    const case = gust.Case{ .vertical = 2, .span = 8 };
    const rows = try gust.respond(&inst, case, &log);
    var peak: f64 = 0;
    var swing: f64 = 0;
    for (log[0..rows]) |row| {
        peak = @max(peak, row.alpha - alpha_trim);
        swing = @max(swing, @abs(row.slosh_x[0] - log[0].slosh_x[0]));
    }
    const kinematic = std.math.atan(case.vertical / case.airspeed);
    try std.testing.expect(peak > 0.3 * kinematic and peak < 1.05 * kinematic);
    try std.testing.expectApproxEqAbs(alpha_trim, log[rows - 1].alpha, 0.5 * deg);
    try std.testing.expect(swing > 1e-4);

    aircraft(&inst.p);
    const locked = try gust.respond(&inst, .{ .vertical = 2, .span = 8, .liquid_free = false }, &log);
    for (log[0..locked]) |row| try std.testing.expectEqual(log[0].slosh_x[0], row.slosh_x[0]);
}

test "rajada em fatias dá o mesmo que de uma vez" {
    aircraft(&inst.p);
    const case = gust.Case{ .vertical = 1, .lateral = 1, .span = 4 };
    const whole = try gust.respond(&inst, case, &log);
    const last = log[whole - 1];
    aircraft(&inst2.p);
    try gust.begin(&inst2, case);
    var rows: usize = 0;
    var sliced: [4096]types.LogRow = undefined;
    while (!try gust.advance(&inst2, case, &sliced, &rows, 0.3)) {}
    try std.testing.expectEqual(whole, rows);
    try std.testing.expectEqual(last.alpha, sliced[rows - 1].alpha);
    try std.testing.expectEqual(last.beta, sliced[rows - 1].beta);
}

test "LAPES solta no meio da rajada: sai do avião e a massa que voa cai o peso dela" {
    // a carga desliza pela rampa com Fext_g·g menos o atrito e sai no fim dela (`physics/mass.zig`); depois disso a
    // massa do avião é a seca mais o líquido
    aircraft(&inst.p);
    inst.p.payload = .{ .enabled = 1, .m = 1.5, .r = .{ -0.1, 0, 0.05 }, .bay = 0.3 };
    const case = gust.Case{ .vertical = 1, .span = 6, .release = 2, .settle = false };
    try gust.begin(&inst, case);
    const loaded = trim.Ctx.init(&inst.p, &inst.r.f).m;
    var rows: usize = 0;
    while (!try gust.advance(&inst, case, &log, &rows, 0.25)) {}
    try std.testing.expect(inst.r.f.released != 0);
    try std.testing.expect(inst.r.ev.trel > 2.0 and inst.r.ev.trel < 3.0); // a rampa de 0,3 m leva uma fração de segundo
    const empty = trim.Ctx.init(&inst.p, &inst.r.f).m;
    try std.testing.expectApproxEqAbs(loaded - 1.5, empty, 1e-9);
}

test "polos da rajada: o líquido livre soma um par perto da frequência do pêndulo; a rajada sobe e desce como 1 − cos" {
    aircraft(&inst.p);
    inst.p.n_tank = 1;
    inst.p.tank[0] = .{ .side = 0.12, .fill = 0.07, .rho = 1000, .zeta = 0.03, .r = .{ 0, 0, 0 } };
    const case = gust.Case{ .vertical = 2, .span = 3 };
    try gust.begin(&inst, case);
    const locked = gust.poles(&inst.p, &inst.r.f, case.airspeed, false);
    const free = gust.poles(&inst.p, &inst.r.f, case.airspeed, true);
    try std.testing.expect(locked.ok and free.ok);
    try std.testing.expectEqual(@as(usize, 8), locked.count);
    try std.testing.expectEqual(@as(usize, 12), free.count);
    // o avião do teste é estável no curto período: algum par com amortecimento (parte real bem negativa)
    var short_period = false;
    for (0..locked.count) |i| short_period = short_period or (locked.real[i] < -2 and locked.imag[i] > 1);
    try std.testing.expect(short_period);
    // o pêndulo: ω₁ = √(g k tanh(k h)), k = π / lado (Abramson, NASA SP-106), com ζ pequeno
    const frequency = inst.p.tank[0].w1;
    var near_pendulum = false;
    for (0..free.count) |i| near_pendulum = near_pendulum or @abs(@sqrt(free.real[i] * free.real[i] + free.imag[i] * free.imag[i]) - frequency) < 0.25 * frequency;
    try std.testing.expect(near_pendulum);
    // a rajada: zero antes, U no meio da duração, zero depois
    try std.testing.expectApproxEqAbs(@as(f64, 0), gust.gustSpeed(&inst.p, 0.5, 1)[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), gust.gustSpeed(&inst.p, 1.5, 1)[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), gust.gustSpeed(&inst.p, 2.5, 1)[0], 1e-12);
    inst.p.n_tank = 0;
}
