//! drive_manager: dono da simulação durante o voo. A cada quadro avança o núcleo até o tempo do
//! quadro e entrega o que as telas precisam: pose da aeronave, comandos das superfícies (δe, δa,
//! δr, acelerador), rotação das hélices, sloshing, carga LAPES e o estado do voo.
//!
//! Quem comanda as superfícies (`setMode`, troca a qualquer momento, sem tranco):
//!   manual      (padrão) os comandos de `setCommands` (controle, já com as curvas) vão direto ao núcleo
//!   autopilot   o piloto automático do núcleo segue o percurso do avião (decolagem, curvas,
//!               passagem LAPES e pouso — o mesmo percurso padrão da GUI), com a mesma calibração
//! `dropPayload` solta a carga LAPES agora (se houver).
const std = @import("std");
const core = @import("aerosim");
const model = @import("../model/aircraft.zig");
const params = @import("params.zig");
const pose = @import("../gfx/pose.zig");
const v3 = @import("../math/vec3.zig");
const fz = @import("../util/fuzz.zig");
const session = @import("session.zig");

const T = core.types;
const L = core.limits;

pub const Mode = session.Mode;

/// comandos de quem pilota (rad e 0..1)
pub const Commands = struct { de: f64 = 0, da: f64 = 0, dr: f64 = 0, thr: f64 = 0 };

pub const Phase = enum { ground_run, flying, landed, crashed, timeout };

/// o que sai a cada quadro
pub const Frame = struct {
    t: f64 = 0,
    pos_ned: v3.V3 = .{ 0, 0, 0 }, // n, e, d
    phi: f64 = 0,
    theta: f64 = 0,
    psi: f64 = 0,
    Va: f64 = 0,
    thr: f64 = 0,
    seg: usize = 0,
    drive: pose.DriveState = .{}, // comandos das superfícies + hélices + líquido + carga
    payload_ned: ?v3.V3 = null, // carga solta (no mundo)
    phase: Phase = .ground_run,
    mode: Mode = .manual,
    rpm: f64 = 0, // do primeiro motor
    current: f64 = 0, // A (bateria)
    energy_wh: f64 = 0,
    alpha: f64 = 0,
    nz: f64 = 1,
    h_ground: f64 = 0, // altura do terreno embaixo (mesa/plataforma)
};

pub const DriveManager = struct {
    gpa: std.mem.Allocator,
    inst: *core.runner.Instance,
    info: params.Info,
    mode: Mode = .manual,
    reset_error: []const u8 = "", // por que o núcleo não pôs o avião na pista (vazio: pôs)
    t: f64 = 0,
    last: ?T.LogRow = null,
    frame: Frame = .{},
    status: core.runner.Status = .chunk,
    buf: [256]T.LogRow = undefined,
    prop_angle: [pose.max_units]f64 = @splat(0),
    n_seg: usize = 0,

    /// monta e calibra a simulação do avião e põe na pista
    pub fn init(gpa: std.mem.Allocator, ac: *const model.Aircraft, diag: *model.Diag, mode: Mode) !DriveManager {
        const inst = try gpa.create(core.runner.Instance);
        errdefer gpa.destroy(inst);
        inst.* = .{};
        const info = try params.setup(ac, inst, diag);
        inst.p.dtlog = 0.005; // várias linhas por quadro (o último estado é o do fim do quadro)
        core.runner.configure(inst) catch return error.CoreConfig;
        var dm: DriveManager = .{ .gpa = gpa, .inst = inst, .info = info, .n_seg = @intCast(inst.p.n_seg), .mode = mode };
        dm.restart() catch |e| {
            diag.set("{s}", .{dm.reset_error});
            return e;
        };
        return dm;
    }

    pub fn deinit(dm: *DriveManager) void {
        dm.gpa.destroy(dm.inst);
    }

    pub fn restart(dm: *DriveManager) !void {
        dm.inst.p.pilot = .{ .manual = @intFromBool(dm.mode == .manual) };
        core.runner.resetGround(dm.inst) catch |e| {
            dm.reset_error = core.runner.stateText(e);
            return error.CoreConfig;
        };
        dm.reset_error = "";
        dm.t = 0;
        dm.last = null;
        dm.status = .chunk;
        dm.prop_angle = @splat(0);
        dm.frame = .{};
    }

    /// troca quem pilota; para o automático, o núcleo assume do estado atual sem tranco
    pub fn setMode(dm: *DriveManager, m: Mode) void {
        if (m == dm.mode) return;
        dm.mode = m;
        switch (m) {
            .autopilot => core.runner.handover(dm.inst),
            .manual => {
                const f = dm.frame;
                dm.inst.p.pilot.manual = 1;
                dm.setCommands(.{ .de = f.drive.de, .da = f.drive.da, .dr = f.drive.dr, .thr = f.thr });
            },
        }
    }

    pub fn toggleMode(dm: *DriveManager) void {
        dm.setMode(if (dm.mode == .manual) .autopilot else .manual);
    }

    /// comandos do controle (só valem no manual); não finitos viram 0, o núcleo satura
    pub fn setCommands(dm: *DriveManager, c: Commands) void {
        const ok = struct {
            fn f(v: f64) f64 {
                return if (std.math.isFinite(v)) v else 0;
            }
        }.f;
        const pl = &dm.inst.p.pilot;
        pl.de = ok(c.de);
        pl.da = ok(c.da);
        pl.dr = ok(c.dr);
        pl.thr = std.math.clamp(ok(c.thr), 0, 1);
    }

    pub fn hasPayload(dm: *const DriveManager) bool {
        return dm.inst.p.payload.enabled != 0;
    }

    /// solta a carga LAPES agora (nada se não tiver ou já soltou)
    pub fn dropPayload(dm: *DriveManager) void {
        if (dm.hasPayload()) dm.inst.p.pilot.drop = 1;
    }

    pub fn finished(dm: *const DriveManager) bool {
        return switch (dm.status) {
            .completed, .crashed, .timeout, .not_ready => true,
            else => false,
        };
    }

    /// avança `dt` segundos de simulação (o quadro); devolve o estado no fim dele
    pub fn step(dm: *DriveManager, dt_in: f64) *const Frame {
        const dt = if (std.math.isFinite(dt_in)) std.math.clamp(dt_in, 0, 0.25) else 0;
        if (dt > 0 and !dm.finished()) {
            const t_target = dm.t + dt;
            var guard: usize = 0;
            while (guard < 64) : (guard += 1) { // o registro pode encher antes do fim do quadro
                var n: usize = 0;
                dm.status = core.runner.run(dm.inst, t_target, &dm.buf, &n);
                if (n > 0) dm.last = dm.buf[n - 1];
                if (dm.status != .buffer_full) break;
            }
            dm.t = t_target;
            if (dm.last) |row| {
                for (0..@min(pose.max_units, L.max_props)) |i| { // rpm -> ângulo da pá (rad)
                    dm.prop_angle[i] += row.rpm[i] * 2 * std.math.pi / 60.0 * dt;
                    dm.prop_angle[i] = @mod(dm.prop_angle[i], 2 * std.math.pi);
                }
            }
        }
        dm.updateFrame();
        return &dm.frame;
    }

    fn updateFrame(dm: *DriveManager) void {
        const row = dm.last orelse return;
        const ev = &dm.inst.r.ev;
        var f: Frame = .{
            .t = row.t,
            .pos_ned = .{ row.n, row.e, -row.h },
            .phi = row.phi,
            .theta = row.theta,
            .psi = row.psi,
            .Va = row.Va,
            .thr = row.thr,
            .seg = @intFromFloat(std.math.clamp(row.seg, 0, 1e6)),
        };
        f.drive = .{ .de = row.de, .da = row.da, .dr = row.dr, .prop_angle = dm.prop_angle, .payload_released = ev.trel > 0 };
        for (0..@min(pose.max_tanks, L.max_tanks)) |i| f.drive.slosh_tilt[i] = .{ row.slosh_y[i], -row.slosh_x[i] };
        if (ev.trel > 0) f.payload_ned = .{ row.pk_n, row.pk_e, -row.pk_h };
        f.mode = dm.mode;
        f.rpm = row.rpm[0];
        f.current = row.Ibat;
        f.energy_wh = row.E;
        f.alpha = row.alpha;
        f.nz = row.nz;
        f.h_ground = row.hgnd;
        f.phase = switch (dm.status) {
            .crashed => .crashed,
            .timeout => .timeout,
            .completed => .landed,
            else => if (ev.tLO > 0) .flying else .ground_run,
        };
        dm.frame = f;
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "piloto automático: o Convencional decola do chão, sobe e segue o percurso" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(bytes);
    var d: model.Diag = .{};
    var l = try model.parse(testing.allocator, bytes, &d);
    defer l.deinit();
    var dm = try DriveManager.init(testing.allocator, &l.ac, &d, .autopilot);
    defer dm.deinit();
    var max_h: f64 = 0;
    var moved_de = false;
    for (0..60 * 40) |_| { // 40 s a 60 quadros por segundo
        const f = dm.step(1.0 / 60.0);
        max_h = @max(max_h, -f.pos_ned[2]);
        if (@abs(f.drive.de) > 0.01) moved_de = true;
        if (dm.finished()) break;
    }
    try testing.expect(dm.frame.phase == .flying);
    try testing.expect(max_h > 10); // subiu para a altura do circuito (15 m)
    try testing.expect(dm.frame.seg >= 1); // passou da perna de decolagem
    try testing.expect(moved_de); // o piloto mexeu no profundor
    try testing.expectApproxEqAbs(@as(f64, 40), dm.t, 1e-6);
}

test "manual: acelerador cheio e profundor cabrando decola; trocar para o automático segue voando" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(bytes);
    var d: model.Diag = .{};
    var l = try model.parse(testing.allocator, bytes, &d);
    defer l.deinit();
    var dm = try DriveManager.init(testing.allocator, &l.ac, &d, .manual);
    defer dm.deinit();
    var t: f64 = 0;
    while (t < 12) : (t += 1.0 / 60.0) { // corrida a pleno, puxa o manche depois de 4 s e alivia no ar
        const pull: f64 = if (t < 4) 0 else if (dm.frame.phase == .flying and -dm.frame.pos_ned[2] > 0.5) -2 else -8;
        dm.setCommands(.{ .thr = 1, .de = std.math.degreesToRadians(pull) });
        _ = dm.step(1.0 / 60.0);
    }
    try testing.expect(dm.frame.phase == .flying and -dm.frame.pos_ned[2] > 2);
    try testing.expectApproxEqAbs(@as(f64, 1), dm.frame.thr, 1e-9);
    dm.setMode(.autopilot);
    while (t < 40) : (t += 1.0 / 60.0) _ = dm.step(1.0 / 60.0);
    try testing.expect(dm.frame.phase == .flying and -dm.frame.pos_ned[2] > 5);
    try testing.expect(dm.frame.mode == .autopilot);
}

var fuzz_ac: ?model.Loaded = null;

fn fuzzSteps(_: void, src: *fz.Src) anyerror!void {
    // sequência qualquer de passos (NaN, negativos, enormes, reinícios): estado sempre finito
    if (fuzz_ac == null) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Asa_voadora.json", testing.allocator, .limited(1 << 24));
        defer testing.allocator.free(bytes);
        var d: model.Diag = .{};
        fuzz_ac = try model.parse(std.heap.page_allocator, bytes, &d);
    }
    var d: model.Diag = .{};
    var dm = try DriveManager.init(testing.allocator, &fuzz_ac.?.ac, &d, if (src.boolean()) .manual else .autopilot);
    defer dm.deinit();
    while (!src.chance(40)) {
        if (src.chance(30)) try dm.restart();
        if (src.chance(15)) dm.toggleMode();
        if (src.chance(20)) dm.dropPayload();
        dm.setCommands(.{ .de = src.any(), .da = src.mostly(-0.3, 0.3), .dr = src.any(), .thr = src.any() });
        const f = dm.step(if (src.chance(6)) src.any() else src.range(0, 0.05));
        try testing.expect(v3.finite(f.pos_ned) and std.math.isFinite(f.drive.de));
        try testing.expect(dm.t >= 0 and std.math.isFinite(dm.t));
    }
}

test "fuzz: passos do drive_manager" {
    try fz.checkScaled({}, fuzzSteps, .{}, 40); // cada caso calibra um avião
}
