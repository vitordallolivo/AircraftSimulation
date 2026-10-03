//! drive_manager: dono da simulação durante o voo. A cada quadro avança o núcleo até o tempo do
//! quadro e entrega o que as telas precisam: pose da aeronave, comandos das superfícies (δe, δa,
//! δr, acelerador), rotação das hélices, sloshing, carga LAPES e o estado do voo.
//!
//! Quem comanda as superfícies:
//!   autopilot   o piloto automático do núcleo segue o percurso do avião (decolagem, curvas,
//!               passagem LAPES e pouso — o mesmo percurso padrão da GUI), com a mesma calibração
//!   (manual / assistido virão na frente C: comandos do controle entrando no núcleo)
const std = @import("std");
const core = @import("aerosim");
const model = @import("../model/aircraft.zig");
const params = @import("params.zig");
const pose = @import("../gfx/pose.zig");
const v3 = @import("../math/vec3.zig");
const fz = @import("../util/fuzz.zig");

const T = core.types;
const L = core.limits;

pub const Mode = enum { autopilot };

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
};

pub const DriveManager = struct {
    gpa: std.mem.Allocator,
    inst: *core.runner.Instance,
    info: params.Info,
    mode: Mode = .autopilot,
    t: f64 = 0,
    last: ?T.LogRow = null,
    frame: Frame = .{},
    status: core.runner.Status = .chunk,
    buf: [256]T.LogRow = undefined,
    prop_angle: [pose.max_units]f64 = @splat(0),
    n_seg: usize = 0,

    /// monta e calibra a simulação do avião e põe na pista
    pub fn init(gpa: std.mem.Allocator, ac: *const model.Aircraft, diag: *model.Diag) !DriveManager {
        const inst = try gpa.create(core.runner.Instance);
        errdefer gpa.destroy(inst);
        inst.* = .{};
        const info = try params.setup(ac, inst, diag);
        inst.p.dtlog = 0.005; // várias linhas por quadro (o último estado é o do fim do quadro)
        core.runner.configure(inst) catch return error.CoreConfig;
        var dm: DriveManager = .{ .gpa = gpa, .inst = inst, .info = info, .n_seg = @intCast(inst.p.n_seg) };
        try dm.restart();
        return dm;
    }

    pub fn deinit(dm: *DriveManager) void {
        dm.gpa.destroy(dm.inst);
    }

    pub fn restart(dm: *DriveManager) !void {
        core.runner.resetGround(dm.inst) catch return error.CoreConfig;
        dm.t = 0;
        dm.last = null;
        dm.status = .chunk;
        dm.prop_angle = @splat(0);
        dm.frame = .{};
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
    var dm = try DriveManager.init(testing.allocator, &l.ac, &d);
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
    var dm = try DriveManager.init(testing.allocator, &fuzz_ac.?.ac, &d);
    defer dm.deinit();
    while (!src.chance(40)) {
        if (src.chance(30)) try dm.restart();
        const f = dm.step(if (src.chance(6)) src.any() else src.range(0, 0.05));
        try testing.expect(v3.finite(f.pos_ned) and std.math.isFinite(f.drive.de));
        try testing.expect(dm.t >= 0 and std.math.isFinite(dm.t));
    }
}

test "fuzz: passos do drive_manager" {
    try fz.checkScaled({}, fuzzSteps, .{}, 40); // cada caso calibra um avião
}
