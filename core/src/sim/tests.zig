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

fn aircraft(p: *types.Params) void {
    p.* = .{ .m_dry = 8.39, .Ixx = 0.9, .Iyy = 1.2, .Izz = 1.9, .Ixz = 0.04, .Sref = 1.0, .cref = 0.4, .bref = 2.5 };
    p.fus_CDS = 0.03;
    p.fus_Cma = 0.1;
    p.fus_Cnb = -0.03;
    p.fus_CYb = -0.15;
    const ARw = 6.25;
    const CLaw = helmbold(5.9, ARw);
    const wing = types.Surface{ .c = 0.4, .AR = ARw, .e = 0.85, .dihedral = 3 * deg, .incidence = 2 * deg, .CLa = CLaw, .CL0 = 0.3, .CLmax = 1.6, .CD0 = 0.012, .Cmac = -0.08 };
    const yi = 0.6 * 2.5 / 4.0;
    const ye = 1.6 * 2.5 / 4.0;
    p.n_surf = 6;
    p.surf[0] = wing;
    p.surf[0].r = .{ 0.035, yi, -0.12 };
    p.surf[0].S = 0.3;
    p.surf[0].side = 1;
    p.surf[1] = wing;
    p.surf[1].r = .{ 0.035, ye, -0.12 };
    p.surf[1].S = 0.2;
    p.surf[1].side = 1;
    p.surf[1].tau = 0.5;
    p.surf[1].mix = .{ 0, -1, 0 };
    p.surf[2] = p.surf[0];
    p.surf[2].r[1] = -yi;
    p.surf[2].side = -1;
    p.surf[3] = p.surf[1];
    p.surf[3].r[1] = -ye;
    p.surf[3].side = -1;
    p.surf[3].mix = .{ 0, 1, 0 };
    const CLw0 = 0.3 + CLaw * 2 * deg;
    p.surf[4] = .{ .group = limits.group_htail, .r = .{ -1.05, 0, -0.05 }, .S = 0.2, .c = @sqrt(0.2 / 4.0), .AR = 4, .incidence = -2 * deg, .CLa = helmbold(5.9, 4), .CLmax = 1.0, .CD0 = 0.012, .tau = 0.5, .mix = .{ 1, 0, 0 }, .eta = 0.9, .downwash = 1, .eps0 = 2 * CLw0 / (std.math.pi * ARw), .depsda = 2 * CLaw / (std.math.pi * ARw) };
    p.surf[5] = .{ .group = limits.group_vtail, .vertical = 1, .r = .{ -1.1, 0, -0.22 }, .S = 0.12, .c = @sqrt(0.12 / 1.6), .AR = 1.6, .CLa = helmbold(5.9, 1.6), .CLmax = 1.0, .CD0 = 0.012, .tau = 0.5, .mix = .{ 0, 0, -1 }, .eta = 0.9 };
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .r = .{ 0.55, 0, 0 }, .tilt = 3 * deg, .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035 };
    const tab = [_][3]f64{ .{ 0, 0.0896, 0.0299 }, .{ 0.1169, 0.0818, 0.0316 }, .{ 0.2338, 0.0706, 0.032 }, .{ 0.3507, 0.0555, 0.0296 }, .{ 0.4676, 0.0368, 0.0239 }, .{ 0.5846, 0.0162, 0.015 }, .{ 0.6781, 0, 0.0062 } };
    u.n_pts = tab.len;
    for (tab, 0..) |r, i| {
        u.J[i] = r[0];
        u.CT[i] = r[1];
        u.CP[i] = r[2];
    }
    p.n_gear = 4;
    p.gear[0] = .{ .kind = types.gear_steer, .r = .{ 0.45, 0, 0.22 }, .k = 2000, .c = 60 };
    p.gear[1] = .{ .kind = types.gear_main, .r = .{ -0.05, -0.3, 0.22 }, .k = 4000, .c = 120 };
    p.gear[2] = .{ .kind = types.gear_main, .r = .{ -0.05, 0.3, 0.22 }, .k = 4000, .c = 120 };
    p.gear[3] = .{ .kind = types.gear_skid, .r = .{ -1.1, 0, 0 }, .k = 6000, .c = 150 };
    p.n_tank = 1;
    p.tank[0] = .{ .r = .{ 0.1, 0, 0.05 }, .shape = types.tank_cylinder, .side = 0.16, .fill = 0.08 };
    p.payload = .{ .enabled = 1, .m = 2, .r = .{ -0.05, 0, 0.08 }, .bay = 0.35 };
    p.takeoff = .{ .sR = 37.5, .de1 = -3 * deg, .rate_de = 60 * deg };
    p.ap.CL0 = 0.398;
    p.ap.CLa = 4.747;
    p.ap.alpha_max = 11 * deg;
    p.n_seg = 2;
    p.seg[0] = .{ .takeoff = 1, .L = 100, .h0 = 15, .h1 = 15, .V0 = 15, .V1 = 15 };
    p.seg[1] = .{ .n0 = 100, .L = 300, .h0 = 15, .h1 = 15, .V0 = 15, .V1 = 15 };
}

var inst: runner.Instance = .{};
var inst2: runner.Instance = .{};
var log: [4096]types.LogRow = undefined;

test "decolagem até h_end" {
    aircraft(&inst.p);
    inst.p.stop_takeoff = 1;
    try runner.configure(&inst);
    try runner.resetGround(&inst);
    var n: usize = 0;
    const st = runner.run(&inst, 1e9, &log, &n);
    try std.testing.expectEqual(runner.Status.completed, st);
    const ev = inst.r.ev;
    try std.testing.expect(ev.tLO > 0 and ev.nLO > 20 and ev.nLO < 80);
    try std.testing.expect(n > 10);
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
        var n: usize = 0;
        const st = runner.run(&inst, 1e9, &log, &n);
        var top: f64 = 0;
        for (log[0..n]) |row| {
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
        fn at(p: *const types.Params, al: f64) f64 {
            const Vr = vec.V3{ 12.0 * @cos(al), 0, 12.0 * @sin(al) };
            return aeromodel.compute(p, Vr, vec.zero, vec.zero, 100.0, vec.zero, &mods.Env.none).ratioCL;
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
    var n: usize = 0;
    try std.testing.expectEqual(runner.Status.stopped, runner.run(&inst, 1e9, &log, &n));
    const snap = inst.r;
    inst.p.stop_t = 9.0;
    _ = runner.run(&inst, 1e9, &log, &n);
    inst2 = inst;
    inst2.r = snap;
    _ = runner.run(&inst2, 1e9, &log, &n);
    try std.testing.expectEqual(inst.r.x[state.N], inst2.r.x[state.N]);
}

test "fatias de tempo continuam sem perder passos" {
    aircraft(&inst.p);
    inst.p.stop_t = 4.0;
    try runner.configure(&inst);
    try runner.resetGround(&inst);
    var n: usize = 0;
    var st = runner.run(&inst, 1.0, &log, &n);
    try std.testing.expectEqual(runner.Status.chunk, st);
    while (st == .chunk) st = runner.run(&inst, inst.r.t + 1.0, &log, &n);
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
    var n: usize = 0;
    _ = runner.run(&inst, 1e9, &log, &n);
    try std.testing.expectApproxEqAbs(@as(f64, 15), -inst.r.x[state.D], 1.0);
}

const linear = @import("linear.zig");

test "linearização: equilíbrio, amortecimentos e acoplamentos" {
    aircraft(&inst.p);
    try runner.configure(&inst);
    const lm = linear.linearize(&inst.p, &inst.r.f, 16);
    try std.testing.expect(lm.ok == 1);
    try std.testing.expect(linear.residual(&inst.p, &inst.r.f, &lm) < 1e-4);
    const A = lm.A;
    const n = linear.nl;
    // u v w p q r φ θ
    try std.testing.expect(A[4 * n + 4] < 0); // M_q
    try std.testing.expect(A[3 * n + 3] < 0); // L_p
    try std.testing.expect(A[5 * n + 5] < 0); // N_r
    try std.testing.expect(A[2 * n + 2] < 0); // Z_w
    try std.testing.expect(A[4 * n + 2] < 0); // M_w: estável em arfagem
    try std.testing.expect(A[5 * n + 1] > 0); // N_v: estável em guinada
    // quase simétrico (só δa, δr de equilíbrio do torque acoplam): v ~ não mexe em q, w em p
    try std.testing.expect(@abs(A[4 * n + 1]) < 0.05 * @abs(A[4 * n + 2]));
    try std.testing.expect(@abs(A[3 * n + 2]) < 0.05 * @abs(A[3 * n + 1]));
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
