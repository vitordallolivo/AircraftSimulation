//! O CG do avião com a carga que a Montagem definiu, e acertar o CG de projeto: o par de `balance.py`. A sprint põe a
//! LAPES e os tanques no CG de projeto; na Montagem se decide quanto pesa cada coisa e onde fica, e isso tira o CG do
//! lugar. "Acertar o CG" move a bateria (a massa pontual com "bateria" no nome) ou, sem ela, o lastro ligado, em x,
//! até o CG com a carga voltar ao x de projeto, sem sair da fuselagem.
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const dims = @import("dims.zig");

const model = aircraft_model.aircraft;
const Aircraft = model.Aircraft;

/// a massa (kg) e o CG (m, eixos do corpo)
pub const Weights = struct { mass: f64, cg: [3]f64 };

/// a massa e o CG com o que vai a bordo (`full_cg`): a massa seca do núcleo (`params.dryMass`), o líquido de cada
/// tanque (densidade × volume, no ponto do tanque) e, com `with_payload`, a carga da LAPES
pub fn fullCg(aircraft: *const Aircraft, with_payload: bool) Weights {
    const dry = aircraft_model.params.dryMass(aircraft);
    var mass = dry.m;
    var moment = [3]f64{ dry.m * dry.cg[0], dry.m * dry.cg[1], dry.m * dry.cg[2] };
    for (aircraft.tanks) |tank| {
        const liquid = tank.rho * tank.volume / 1000.0;
        if (!(tank.volume > 0)) continue;
        mass += liquid;
        for (&moment, [3]f64{ tank.x, tank.y, tank.z }) |*sum, where| sum.* += liquid * where;
    }
    const payload = aircraft.payload;
    if (with_payload and payload.enabled and payload.mass > 0) {
        mass += payload.mass;
        for (&moment, [3]f64{ payload.x, payload.y, payload.z }) |*sum, where| sum.* += payload.mass * where;
    }
    var cg = moment;
    if (mass > 0) for (&cg) |*center| {
        center.* /= mass;
    };
    return .{ .mass = mass, .cg = cg };
}

/// o que "Acertar o CG" moveu
pub const Mover = union(enum) {
    item: usize, // a massa pontual `mass.items[i]` (a bateria)
    ballast,
};

/// o resultado de `rebalance`: a peça, o x novo e a mensagem para a tela
pub const Rebalance = struct {
    ok: bool,
    mover: ?Mover = null,
    x: f64 = 0,
    message: []const u8,
};

/// a CMA da asa principal (a primeira de papel "wing"), pela planta de `dims.planform`
fn meanChord(aircraft: *const Aircraft) f64 {
    for (aircraft.surfaces) |*surface| {
        if (std.mem.eql(u8, surface.role, "wing") and surface.sections.len > 0) return dims.planform(surface).chord;
    }
    return std.math.nan(f64);
}

/// move a bateria (ou o lastro) em x para o CG com a carga voltar ao x de projeto (`rebalance`). Dentro da
/// fuselagem, se ela existe (5 cm das pontas); se não alcança, diz quanto faltou em % da CMA. Não muda o avião:
/// quem chama grava `x` na peça de `mover`
pub fn rebalance(memory: std.mem.Allocator, aircraft: *const Aircraft) !Rebalance {
    const design = aircraft.design_cg orelse return .{ .ok = false, .message = "o avião não tem CG de projeto (não veio da sprint): nada a acertar" };
    const target = design[0];
    var mover: Mover = undefined;
    var what: []const u8 = undefined;
    var old_x: f64 = 0;
    var moved_mass: f64 = 0;
    const battery = for (aircraft.mass.items, 0..) |item, i| {
        if (std.ascii.indexOfIgnoreCase(item.name, "bateria") != null) break i;
    } else null;
    if (battery) |i| {
        mover = .{ .item = i };
        what = "bateria";
        old_x = aircraft.mass.items[i].x;
        moved_mass = aircraft.mass.items[i].mass;
    } else if (aircraft.ballast.enabled and aircraft.ballast.mass > 0) {
        mover = .ballast;
        what = "lastro";
        old_x = aircraft.ballast.x;
        moved_mass = aircraft.ballast.mass;
    } else return .{ .ok = false, .message = "não há bateria (massa pontual) nem lastro ligado para mover" };
    const before = fullCg(aircraft, true);
    if (@abs(before.cg[0] - target) < 1e-6) return .{ .ok = true, .message = "o CG já está no de projeto" };
    const wanted = old_x + (target - before.cg[0]) * before.mass / moved_mass;
    const fuselage = aircraft.fuselage;
    const low = if (fuselage.enabled) fuselage.x_nose - fuselage.length + 0.05 else -std.math.inf(f64);
    const high = if (fuselage.enabled) fuselage.x_nose - 0.05 else std.math.inf(f64);
    const x = std.math.clamp(wanted, low, high);
    // o CG com a peça no lugar novo (uma cópia do avião só com ela mudada)
    var moved = aircraft.*;
    switch (mover) {
        .item => |i| {
            const items = try memory.dupe(model.PointMass, aircraft.mass.items);
            items[i].x = x;
            moved.mass.items = items;
        },
        .ballast => moved.ballast.x = x,
    }
    const after = fullCg(&moved, true);
    const miss = (after.cg[0] - target) / meanChord(aircraft) * 100;
    if (@abs(x - wanted) > 1e-9) return .{ .ok = false, .mover = mover, .x = x, .message = try std.fmt.allocPrint(memory, "{s}: x {d:.3} → {d:.3} m (no limite da fuselagem); o CG ainda fica {d:.1} % CMA do de projeto: mude a posição da carga ou use lastro", .{ what, old_x, x, miss }) };
    return .{ .ok = true, .mover = mover, .x = x, .message = try std.fmt.allocPrint(memory, "{s}: x {d:.3} → {d:.3} m; o CG voltou ao de projeto", .{ what, old_x, x }) };
}

test "Acertar o CG move a bateria até o CG de projeto, e para no limite da fuselagem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.aero", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    // o exemplo não tem bateria: uma de 0,8 kg em x = 0 (só na memória do teste)
    const battery = model.PointMass{ .name = "bateria", .mass = 0.8, .x = 0, .y = 0, .z = 0.02 };
    const items = try std.mem.concat(memory, model.PointMass, &.{ loaded.ac.mass.items, &.{battery} });
    loaded.ac.mass.items = items;
    const index = items.len - 1;
    const before = fullCg(&loaded.ac, true);
    // um CG de projeto 2 cm à frente: a bateria anda Δx = 0,02·m/m_bateria para frente e o CG chega lá
    const target = before.cg[0] + 0.02;
    loaded.ac.design_cg = .{ target, 0, 0 };
    const reached = try rebalance(memory, &loaded.ac);
    try std.testing.expect(reached.ok);
    try std.testing.expectEqual(Mover{ .item = index }, reached.mover.?);
    try std.testing.expectApproxEqAbs(0.02 * before.mass / 0.8, reached.x, 1e-9);
    items[index].x = reached.x;
    try std.testing.expectApproxEqAbs(target, fullCg(&loaded.ac, true).cg[0], 1e-9);
    // um CG de projeto 1 m à frente não se alcança: a bateria para 5 cm antes do nariz
    items[index].x = 0;
    loaded.ac.design_cg = .{ before.cg[0] + 1.0, 0, 0 };
    const short = try rebalance(memory, &loaded.ac);
    try std.testing.expect(!short.ok);
    try std.testing.expectApproxEqAbs(loaded.ac.fuselage.x_nose - 0.05, short.x, 1e-12);
    try std.testing.expect(std.mem.indexOf(u8, short.message, "% CMA") != null);
}
