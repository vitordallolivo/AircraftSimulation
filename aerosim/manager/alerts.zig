//! Os avisos que aparecem na tela na hora de rodar: condições em que um método sai do que ele foi feito para
//! calcular e os números podem não valer. A tela (`aerosim/gui/page.zig`) pede os avisos da análise antes de
//! começar a rodada e mostra cada um por cima da janela; a rodada segue igual.
//!
//! O primeiro é a linha sustentadora numa asa curta. A teoria da linha sustentadora troca a asa por uma linha de
//! vórtices no 1/4 da corda, o que só vale quando a envergadura é bem maior que a corda; numa asa de alongamento
//! baixo a corda pesa e o método passa a errar, às vezes sem convergir (Anderson, *Fundamentals of Aerodynamics*,
//! cap. 5: a linha sustentadora de Prandtl para alongamento moderado e alto, a superfície sustentadora para o
//! baixo; o limite AR < 4 é o do dono do repositório, a conferir no PDF).
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");

const params = aircraft_model.params;

/// abaixo deste alongamento a linha sustentadora avisa
pub const min_aspect_ratio = 4.0;

/// o aviso da linha sustentadora (`method`, o nome na tela) numa asa de alongamento menor que `min_aspect_ratio`:
/// confere cada superfície de sustentação ligada (as "wing"); com `include`, só as marcadas nos campos `surf_<i>`
/// (o padrão do campo é ligado nas asas). Nulo: nenhuma asa curta
pub fn shortWing(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, method: []const u8, include: ?simulation.Values) !?[]const u8 {
    for (aircraft.surfaces, 0..) |*surface, index| {
        if (!surface.enabled or surface.vertical) continue;
        const is_wing = std.mem.eql(u8, surface.role, "wing");
        if (include) |values| {
            var key: [32]u8 = undefined;
            if (!values.toggle(std.fmt.bufPrint(&key, "surf_{d}", .{index}) catch continue, is_wing)) continue;
        } else if (!is_wing) continue;
        const area = params.area(surface);
        if (area <= 0) continue;
        const span = params.span(surface);
        const aspect = span * span / area;
        if (aspect >= min_aspect_ratio) continue;
        return try std.fmt.allocPrint(memory, "Rodar a {s} com AR = {d:.1} em '{s}' (menor que {d:.0}) pode fazer os valores divergirem: a linha sustentadora é para asas alongadas. Compare com as faixas ou com o VLM.", .{ method, aspect, surface.name, min_aspect_ratio });
    }
    return null;
}

/// os avisos da rodada da análise `analysis` com estes valores: os dela (`Simulation.alerts`) e o do modelo do voo
/// pela linha sustentadora (o campo `aero_model` dos métodos, em qualquer análise que voa o avião)
pub fn forRun(memory: std.mem.Allocator, analysis: *const simulation.Simulation, aircraft: *const simulation.Aircraft, values: simulation.Values) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (analysis.alerts) |own| try out.appendSlice(memory, try own(memory, aircraft, values));
    const flight = values.text("aero_model", "");
    if (core.methods.byName(core.types.AeroModel, flight) == .lifting_line) {
        if (try shortWing(memory, aircraft, "linha sustentadora (modelo do voo)", null)) |text| try out.append(memory, text);
    }
    return out.items;
}

test "asa curta avisa e asa alongada não" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const model = aircraft_model.aircraft;
    // b = 1 m e corda 0,4 m: AR = 2,5; com corda 0,2 m: AR = 5
    const short_sections = [_]model.Section{ .{ .y = 0, .chord = 0.4 }, .{ .y = 0.5, .chord = 0.4 } };
    const long_sections = [_]model.Section{ .{ .y = 0, .chord = 0.2 }, .{ .y = 0.5, .chord = 0.2 } };
    var plane: model.Aircraft = .{ .name = "teste", .surfaces = &.{.{ .name = "asa", .role = "wing", .sections = &short_sections }} };
    try std.testing.expect(try shortWing(memory, &plane, "linha sustentadora", null) != null);
    plane.surfaces = &.{.{ .name = "asa", .role = "wing", .sections = &long_sections }};
    try std.testing.expect(try shortWing(memory, &plane, "linha sustentadora", null) == null);
}
