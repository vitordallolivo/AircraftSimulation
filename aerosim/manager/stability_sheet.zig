//! A planilha de estabilidade e controle que o programa gera depois de simular, no formato da planilha de saídas de
//! E&C das equipes: uma aba com o nome do avião e, no alto, a velocidade de referência e a massa; embaixo, lado a
//! lado, um bloco por superfície (com dois EH, por exemplo, saem dois blocos de EH, cada um com o seu braço e o seu
//! volume de cauda, mais o volume de todos juntos):
//!
//! - o estabilizador horizontal: perfil, margem estática, incidência, envergadura, CMA, área, braço de cauda,
//!   eficiência, alongamento, volume de cauda, C_Lmax, C_Lα, C_L0, C_mα e C_m0 da fuselagem, C_mac, α de
//!   equilíbrio, ε0, dε/dα, a distância do CA da asa ao CG, a eficácia do profundor e as deflexões máximas;
//! - o estabilizador vertical: envergadura, cordas da raiz, da ponta e média, área, braço, C_nβ, afilamento,
//!   alongamento, perfil, volume de cauda, eficácia do leme, deflexões e C_Lα;
//! - cada aileron das asas: razão de cordas, envergadura, cordas no começo e no fim, onde começa e termina, deflexões;
//! - as derivadas no CG (as de ângulo por grau, as de taxa por radiano).
//!
//! Os números saem do modelo do avião (geometria, comandos, limites do piloto automático) e do avião inteiro no CG
//! pelas faixas do núcleo (`aerodynamics.stabilitySheet`: derivadas, ponto neutro, margem, α de equilíbrio); aqui só
//! se arruma em células.
const std = @import("std");
const core = @import("aerosim");
const simulation = @import("simulation");
const aircraft_model = @import("aircraft_model");
const aerodynamics = @import("simulations/aerodynamics.zig");
const stability = @import("simulations/stability.zig");

const writer = core.xlsx_writer;
const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const deg = 180.0 / std.math.pi;
const nan = std.math.nan(f64);

/// a faixa de α da polar no CG (°), para o α de equilíbrio e o ponto neutro
const alpha_first = -6.0;
const alpha_last = 16.0;

/// as colunas de um bloco: nome, símbolo, unidade e valor. Os blocos ficam lado a lado, um a cada `block_width`
/// colunas a partir da B (o primeiro em B, H, I, L, como na planilha da equipe)
const Block = struct {
    name: u32,
    symbol: u32,
    unit: u32,
    value: u32,

    fn at(index: u32) Block {
        const start = 2 + block_width * index;
        return .{ .name = start, .symbol = start + 6, .unit = start + 7, .value = start + 10 };
    }
};
const block_width = 13;
const header_row = 4;
const first_row = 6;

/// a pasta de trabalho de E&C do avião; devolve os bytes do `.xlsx`
pub fn workbook(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft) ![]const u8 {
    var run: simulation.Run = .{ .arena = .init(memory), .aircraft = aircraft };
    const count: usize = @intFromFloat(alpha_last - alpha_first + 1);
    const alphas = try memory.alloc(f64, count);
    for (alphas, 0..) |*alpha, k| alpha.* = alpha_first + @as(f64, @floatFromInt(k));
    const airspeed = aerodynamics.cruise(aircraft);
    const found = try aerodynamics.stabilitySheet(&run, airspeed, alphas, 2);
    var sheet = writer.Sheet{ .name = try writer.sheetName(memory, aircraft.name) };
    try fill(memory, &sheet, aircraft, found);
    var sheets = [_]writer.Sheet{sheet};
    return writer.write(memory, &sheets);
}

/// a primeira superfície ligada com o papel `role`
fn firstOf(aircraft: *const simulation.Aircraft, role: []const u8) ?*const model.Surface {
    for (aircraft.surfaces) |*surface| if (surface.enabled and std.mem.eql(u8, surface.role, role)) return surface;
    return null;
}

/// o primeiro comando do tipo `kind` da superfície
fn controlOf(surface: ?*const model.Surface, kind: []const u8) ?model.Control {
    const owner = surface orelse return null;
    for (owner.controls) |control| if (std.mem.eql(u8, control.kind, kind)) return control;
    return null;
}

/// a envergadura da superfície (as duas metades, se simétrica) e a corda da raiz e da ponta
fn spanOf(surface: *const model.Surface) struct { span: f64, root: f64, tip: f64 } {
    var buffer: [model.limits.sections]model.Section = undefined;
    const sections = model.sortedSections(surface, &buffer);
    if (sections.len == 0) return .{ .span = nan, .root = nan, .tip = nan };
    const half = sections[sections.len - 1].y - sections[0].y;
    return .{ .span = if (surface.symmetric) 2 * half else half, .root = sections[0].chord, .tip = sections[sections.len - 1].chord };
}

/// a corda da superfície na posição `y` da envergadura (m)
fn chordAt(surface: *const model.Surface, y: f64) f64 {
    var buffer: [model.limits.sections]model.Section = undefined;
    return model.sectionAt(model.sortedSections(surface, &buffer), y, "chord");
}

/// a escrita de um bloco: o título em cima e uma linha por parâmetro
const Writer = struct {
    memory: std.mem.Allocator,
    sheet: *writer.Sheet,
    block: Block,
    row: u32 = first_row,

    fn title(self: *Writer, heading: []const u8, right: u32) !void {
        try self.sheet.text(self.memory, header_row, self.block.name, heading, .header);
        try self.sheet.merge(self.memory, header_row, self.block.name, header_row, right, .header);
        try self.sheet.text(self.memory, header_row + 1, self.block.symbol, "Símbolo", .yellow_label);
        try self.sheet.text(self.memory, header_row + 1, self.block.unit, "Un.", .yellow_label);
        try self.sheet.text(self.memory, header_row + 1, self.block.value, "Valor", .yellow_label);
    }

    fn number(self: *Writer, name: []const u8, symbol: []const u8, unit: []const u8, value: f64) !void {
        try self.labels(name, symbol, unit);
        try self.sheet.number(self.memory, self.row, self.block.value, value, .light_green_value);
        self.row += 1;
    }

    fn text(self: *Writer, name: []const u8, symbol: []const u8, unit: []const u8, value: []const u8) !void {
        try self.labels(name, symbol, unit);
        try self.sheet.text(self.memory, self.row, self.block.value, value, .light_green_value);
        self.row += 1;
    }

    fn labels(self: *Writer, name: []const u8, symbol: []const u8, unit: []const u8) !void {
        try self.sheet.text(self.memory, self.row, self.block.name, name, .pink_label);
        try self.sheet.merge(self.memory, self.row, self.block.name, self.row, self.block.symbol - 1, .pink_label);
        try self.sheet.text(self.memory, self.row, self.block.symbol, symbol, .cyan_label);
        try self.sheet.text(self.memory, self.row, self.block.unit, unit, .yellow_label);
    }
};

/// o braço (CG ao CA da superfície, m) e o volume de cauda de uma superfície só; `span_or_chord` é a corda de
/// referência para o EH e a envergadura para o EV (volume de cauda, Raymer, Aircraft Design, cap. 6; equação a
/// conferir no PDF), a mesma conta de `stability.tailVolumes`, que soma todas
fn tailOf(aircraft: *const simulation.Aircraft, surface: *const model.Surface, x_cg: f64, reference_area: f64, span_or_chord: f64) struct { arm: f64, volume: f64 } {
    const arm = x_cg - stability.meanChord(aircraft, surface).x_center;
    return .{ .arm = arm, .volume = params_mod.area(surface) * arm / (reference_area * span_or_chord) };
}

/// quantas superfícies ligadas têm o papel `role`
fn countOf(aircraft: *const simulation.Aircraft, role: []const u8) usize {
    var count: usize = 0;
    for (aircraft.surfaces) |*surface| count += @intFromBool(surface.enabled and std.mem.eql(u8, surface.role, role));
    return count;
}

/// o título do bloco: o nome do papel e, com mais de uma superfície nesse papel, o nome dela
fn blockTitle(memory: std.mem.Allocator, heading: []const u8, surface: *const model.Surface, several: bool) ![]const u8 {
    if (!several) return heading;
    return std.fmt.allocPrint(memory, "{s} · {s}", .{ heading, surface.name });
}

/// a aba inteira: um bloco por estabilizador horizontal, um por vertical e um por asa com aileron, lado a lado, e
/// as derivadas do avião montado no fim
fn fill(memory: std.mem.Allocator, sheet: *writer.Sheet, aircraft: *const simulation.Aircraft, found: aerodynamics.StabilitySheet) !void {
    const wing = firstOf(aircraft, "wing");
    const geometry = found.geometry;
    const references = params_mod.references(aircraft);
    const volumes = stability.tailVolumes(aircraft, found.cg[0], references);
    const downwash = params_mod.wingDownwash(aircraft) catch [2]f64{ nan, nan };
    const autopilot = aircraft.autopilot;
    const derivatives = found.polar.derivatives;
    const horizontal_count = countOf(aircraft, "htail");
    const vertical_count = countOf(aircraft, "vtail");
    var next_block: u32 = 0;

    // os estabilizadores horizontais
    for (aircraft.surfaces) |*surface| {
        if (!surface.enabled or !std.mem.eql(u8, surface.role, "htail")) continue;
        var horizontal: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
        next_block += 1;
        try horizontal.title(try blockTitle(memory, "ESTABILIZADOR HORIZONTAL", surface, horizontal_count > 1), horizontal.block.value);
        const coefficients = params_mod.coeffs(surface) catch null;
        const extent = spanOf(surface);
        const mean = stability.meanChord(aircraft, surface);
        const elevator = controlOf(surface, "elevator");
        const own = tailOf(aircraft, surface, found.cg[0], references[0], references[1]);
        try horizontal.text("Perfil", "", "-", surface.airfoil.name);
        try horizontal.number("Margem estática", "ME", "-", if (found.metrics.static_margin) |margin| margin / 100 else nan);
        try horizontal.number("Ângulo de incidência EH", "it", "deg", surface.incidence);
        try horizontal.number("Envergadura da EH", "bh", "m", extent.span);
        try horizontal.number("Corda da EH", "MACh", "m", mean.chord);
        try horizontal.number("Área da EH", "Sh", "m²", params_mod.area(surface));
        try horizontal.number("Braço de cauda EH (CG ao CA da EH)", "lh", "m", own.arm);
        try horizontal.number("Eficiência da EH", "eta_h", "-", surface.eta);
        try horizontal.number("Razão de aspecto", "ARh", "-", if (coefficients) |c| c.AR else nan);
        try horizontal.number("Volume de cauda horizontal", "Vh", "-", own.volume);
        if (horizontal_count > 1) try horizontal.number("Volume de cauda de todos os EH", "Vh,total", "-", volumes.horizontal);
        try horizontal.number("CLmax EH", "CLmaxh", "-", if (coefficients) |c| c.CLmax else nan);
        try horizontal.number("CLalpha EH", "CLalphah", "1/deg", if (coefficients) |c| c.CLa / deg else nan);
        try horizontal.number("CL0", "CL0h", "-", if (coefficients) |c| c.CL0 else nan);
        try horizontal.number("Cmalpha da fuselagem", "Cmalphaf", "-", if (aircraft.fuselage.enabled) aircraft.fuselage.Cma else 0);
        try horizontal.number("CMac do EH", "CMach", "-", if (coefficients) |c| c.Cmac else nan);
        try horizontal.number("Alpha de equilíbrio", "alpha_trim", "deg", found.alpha_trim orelse nan);
        try horizontal.number("Downwash a zero grau", "epsilon0", "deg", downwash[0] * deg);
        try horizontal.number("Variação do downwash com alpha", "depsilon/dalpha", "-", downwash[1]);
        const wing_center = if (wing) |owner| stability.meanChord(aircraft, owner).x_center else nan;
        try horizontal.number("Distância CA-CG", "xCG-ACw", "%MACw", (wing_center - found.cg[0]) / geometry.chord);
        try horizontal.number("Parâmetro de eficácia da EH", "tauE_profundor", "-", if (elevator) |control| control.tau orelse nan else nan);
        try horizontal.number("Deflexão máxima positiva", "δe,max", "deg", autopilot.de_max);
        try horizontal.number("Deflexão máxima negativa", "δe,min", "deg", -autopilot.de_max);
    }
    if (horizontal_count == 0) {
        var horizontal: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
        next_block += 1;
        try horizontal.title("ESTABILIZADOR HORIZONTAL", horizontal.block.value);
        try horizontal.text("Sem estabilizador horizontal", "", "", "—");
    }

    // os estabilizadores verticais
    for (aircraft.surfaces) |*surface| {
        if (!surface.enabled or !std.mem.eql(u8, surface.role, "vtail")) continue;
        var vertical: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
        next_block += 1;
        try vertical.title(try blockTitle(memory, "ESTABILIZADOR VERTICAL", surface, vertical_count > 1), vertical.block.value);
        const coefficients = params_mod.coeffs(surface) catch null;
        const extent = spanOf(surface);
        const rudder = controlOf(surface, "rudder");
        const own = tailOf(aircraft, surface, found.cg[0], references[0], references[2]);
        try vertical.number("Envergadura da EV", "bv", "m", extent.span);
        try vertical.number("Corda na raiz da EV", "crv", "m", extent.root);
        try vertical.number("Corda na ponta da EV", "ctv", "m", extent.tip);
        try vertical.number("Corda média da EV", "MACv", "m", stability.meanChord(aircraft, surface).chord);
        try vertical.number("Área da EV", "Sv", "m²", params_mod.area(surface));
        try vertical.number("Braço de cauda EV (CG ao CA da EV)", "lv", "m", own.arm);
        try vertical.number("Taxa de variação do momento em Z", "Cnβ", "1/deg", derivatives.get(.Cnb) / deg);
        try vertical.number("Afilamento da EV", "lambdav", "-", extent.tip / extent.root);
        try vertical.number("Razão de aspecto", "ARv", "-", if (coefficients) |c| c.AR else nan);
        try vertical.text("Perfil", "nperfilv", "-", surface.airfoil.name);
        try vertical.number("Volume de cauda vertical", "Vv", "-", own.volume);
        if (vertical_count > 1) try vertical.number("Volume de cauda de todas as EV", "Vv,total", "-", volumes.vertical);
        try vertical.number("Parâmetro de eficácia da EV", "tauE_leme", "-", if (rudder) |control| control.tau orelse nan else nan);
        try vertical.number("Deflexão máxima positiva", "δr,max", "deg", autopilot.dr_max);
        try vertical.number("CLalpha EV", "CLalphav", "1/deg", if (coefficients) |c| c.CLa / deg else nan);
        try vertical.number("Deflexão máxima negativa", "δr,min", "deg", -autopilot.dr_max);
    }
    if (vertical_count == 0) {
        var vertical: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
        next_block += 1;
        try vertical.title("ESTABILIZADOR VERTICAL", vertical.block.value);
        try vertical.text("Sem estabilizador vertical", "", "", "—");
    }

    // os ailerons: um bloco por aileron de cada asa
    const wing_count = countOf(aircraft, "wing");
    var aileron_count: usize = 0;
    for (aircraft.surfaces) |*surface| {
        if (!surface.enabled or !std.mem.eql(u8, surface.role, "wing")) continue;
        for (surface.controls) |aileron| {
            if (!std.mem.eql(u8, aileron.kind, "aileron")) continue;
            aileron_count += 1;
            var aileron_writer: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
            next_block += 1;
            try aileron_writer.title(try blockTitle(memory, "AILERON", surface, wing_count > 1), aileron_writer.block.value);
            const half = spanOf(surface).span / (if (surface.symmetric) @as(f64, 2) else 1);
            const start = aileron.span_start * half;
            const finish = aileron.span_end * half;
            try aileron_writer.number("Razão entre cordas", "ca/cw", "-", aileron.chord_frac);
            try aileron_writer.number("Envergadura do aileron", "ba", "m", finish - start);
            try aileron_writer.number("Corda no começo", "ci", "m", aileron.chord_frac * chordAt(surface, start));
            try aileron_writer.number("Corda no fim", "cf", "m", aileron.chord_frac * chordAt(surface, finish));
            try aileron_writer.number("Início do aileron", "yi", "m", start);
            try aileron_writer.number("Final do aileron", "yf", "m", finish);
            try aileron_writer.number("Deflexão positiva", "δA", "deg", autopilot.da_max);
            try aileron_writer.number("Deflexão negativa", "δA", "deg", -autopilot.da_max);
        }
    }
    if (aileron_count == 0) {
        var aileron_writer: Writer = .{ .memory = memory, .sheet = sheet, .block = .at(next_block) };
        next_block += 1;
        try aileron_writer.title("AILERON", aileron_writer.block.value);
        try aileron_writer.text("Sem aileron nas asas", "", "", "—");
    }

    // as derivadas do avião montado, no CG
    const derivative_name = Block.at(next_block).name;
    const derivative_value = derivative_name + 1;
    const incidence = if (wing) |surface| surface.incidence else nan;
    try sheet.text(memory, header_row, derivative_name, "DERIVADAS", .header);
    try sheet.text(memory, header_row, derivative_value, try std.fmt.allocPrint(memory, "iw = {d:.1}°", .{incidence}), .header);
    try sheet.text(memory, header_row + 1, derivative_name, "xCG %MACw", .yellow_label);
    try sheet.number(memory, header_row + 1, derivative_value, 100 * (geometry.mac_le - found.cg[0]) / geometry.chord, .light_green_value);
    var row: u32 = first_row;
    for (std.enums.values(aerodynamics.Derivative)) |derivative| {
        const name = @tagName(derivative);
        // as de taxa (p, q, r) ficam por radiano; as de ângulo e de comando, por grau
        const rate = name.len >= 3 and (name[name.len - 1] == 'q' or name[name.len - 1] == 'p' or name[name.len - 1] == 'r') and !std.mem.endsWith(u8, name, "dr");
        const value = derivatives.get(derivative);
        try sheet.text(memory, row, derivative_name, try std.fmt.allocPrint(memory, "{s} ({s})", .{ name, if (rate) "1/rad" else "1/deg" }), .pink_label);
        try sheet.number(memory, row, derivative_value, if (rate) value else value / deg, .light_green_value);
        row += 1;
    }

    // o título, a velocidade e a massa, de ponta a ponta dos blocos
    const last_value = Block.at(next_block - 1).value;
    try sheet.text(memory, 2, 2, try std.fmt.allocPrint(memory, "{s} iw={d:.1}°", .{ aircraft.name, incidence }), .wing_title);
    try sheet.merge(memory, 2, 2, 2, last_value, .wing_title);
    try sheet.text(memory, 3, 2, "VELOCIDADE DE REFERÊNCIA", .header);
    try sheet.text(memory, 3, 12, try std.fmt.allocPrint(memory, "{d:.1} m/s", .{found.airspeed}), .header);
    try sheet.text(memory, 3, 15, "MTOW", .header);
    try sheet.text(memory, 3, 25, try std.fmt.allocPrint(memory, "{d:.2} kg", .{found.mass}), .header);

    // as larguras: as mesmas em todo bloco
    for (0..next_block) |index| {
        const block = Block.at(@intCast(index));
        try sheet.width(memory, block.name, 27);
        try sheet.width(memory, block.symbol, 15);
        try sheet.width(memory, block.unit, 9);
        try sheet.width(memory, block.value, 13);
    }
    try sheet.width(memory, derivative_name, 16);
    try sheet.width(memory, derivative_value, 13);
}

test "a planilha de E&C do avião de exemplo: EH, EV, aileron e derivadas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Convencional_original.aero", memory, .limited(1 << 24));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const book = try core.xlsx.Workbook.parse(memory, try workbook(memory, &loaded.ac));
    try std.testing.expectEqual(@as(usize, 1), book.sheets.len);
    const corner = book.sheets[0].byAddress("B4") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ESTABILIZADOR HORIZONTAL", corner.text);
}

test "dois EH viram dois blocos, cada um com o seu volume, e o total soma os dois" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Convencional_original.aero", memory, .limited(1 << 24));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var aircraft = loaded.ac;
    const tail = firstOf(&aircraft, "htail") orelse return error.TestUnexpectedResult;
    var upper = tail.*;
    upper.name = "EH superior";
    upper.z -= 0.25;
    aircraft.surfaces = try std.mem.concat(memory, model.Surface, &.{ aircraft.surfaces, &.{upper} });
    const book = try core.xlsx.Workbook.parse(memory, try workbook(memory, &aircraft));
    const sheet = book.sheets[0];
    const second = sheet.byAddress("O4") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ESTABILIZADOR HORIZONTAL · EH superior", second.text);
    // a linha 15 é o volume de cada EH e a 16, o de todos: com dois EH iguais, o total é o dobro
    const own = sheet.byAddress("L15") orelse return error.TestUnexpectedResult;
    const total = sheet.byAddress("L16") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqRel(2 * own.number, total.number, 1e-9);
}
