//! Efeito solo: métodos para o fator do arrasto induzido perto do chão.
//!
//! McCormick (padrão; o que o núcleo sempre usou):
//!   φ = (16 h/b)² / (1 + (16 h/b)²),   C_Di(solo) = φ · C_Di
//! B. W. McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics* (Wiley); a mesma expressão é usada
//! por J. D. Anderson, *Aircraft Performance and Design* (McGraw-Hill), citando o McCormick.
//! h: altura do painel acima do chão; b: envergadura de referência.
//!
//! Imagem no VLM (`vlm_image`): o McCormick só mexe no induzido, e perto do chão ele corta o induzido demais e não
//! muda o C_L nem o C_m, que são o que muda a rotação e a saída do chão. O VLM com o chão espelhado
//! (`loads/vlm.zig`, `groundCoefficients`) dá os três, mas é caro demais para o passo do voo. Por isso ele roda uma
//! vez, ao configurar (`buildTable`), numa grade pequena de alturas e α, e no voo só se interpola (`lookup`). As
//! alturas da grade são as da asa (h/b de 0,04 a 3) convertidas para a altura da origem do corpo, a mesma que a
//! simulação passa para a aerodinâmica. Acima da última altura, vale a última linha (quase sem efeito).
const std = @import("std");
const fmath = @import("../math/fmath.zig");
const modifier_types = @import("types.zig");
const types = @import("../types.zig");
const limits = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const vlm = @import("../loads/vlm.zig");

/// fator do arrasto induzido do método `method` (`Params.ground`) a uma altura `height` (m)
/// com envergadura `span` (m)
pub inline fn factor(method: modifier_types.Ground, height: f64, span: f64) f64 {
    return switch (method) {
        .mccormick => mccormick(height, span),
        .off, .vlm_image, _ => 1.0, // a imagem no VLM entra pela tabela (`lookup`), não por painel
    };
}

/// φ de McCormick (ver o cabeçalho). height ≤ 0,01 m é tratado como 0,01 m (o painel não atravessa o chão)
pub inline fn mccormick(height: f64, span: f64) f64 {
    const r16 = 16.0 * @max(height, 0.01) / span;
    return r16 * r16 / (1.0 + r16 * r16);
}

/// a malha do VLM da tabela: 2 painéis na corda de cada faixa (as faixas já dividem a envergadura)
const table_grid: vlm.Grid = .{ .chordwise = 2, .spanwise = 1 };
const max_panels = limits.max_surfaces * 2;
/// as alturas da tabela acima da do avião parado no trem, em envergaduras, e os α (graus)
const lift_heights = [types.GroundTable.heights]f64{ 0, 0.03, 0.07, 0.12, 0.2, 0.35, 0.6, 1.2, 3.0 };
const table_alphas = [types.GroundTable.alphas]f64{ -4, 0, 4, 8, 12, 16 };
/// o α (graus) em que o fator do induzido é medido (C_L longe de zero)
const induced_alpha = 8.0;

/// a memória do VLM da tabela, uma por thread (a conta roda uma vez, ao configurar)
threadlocal var work_panels: [max_panels]vlm.Panel = undefined;
threadlocal var work_matrix: [max_panels * max_panels]f64 = undefined;
threadlocal var work_pivots: [max_panels]usize = undefined;
threadlocal var work_gamma: [max_panels]f64 = undefined;

/// a altura da origem do corpo com o avião parado no trem: a do ponto de trem mais baixo (z para baixo), ou a da
/// faixa mais baixa se o avião não tem trem
fn restingHeight(params: *const types.Params) f64 {
    var lowest: f64 = 0;
    const n_gear: usize = @intCast(@max(params.n_gear, 0));
    for (params.gear[0..n_gear]) |*gear| lowest = @max(lowest, gear.r[2]);
    if (n_gear > 0) return lowest;
    const n_surf: usize = @intCast(@max(params.n_surf, 0));
    for (params.surf[0..n_surf]) |*surface| lowest = @max(lowest, surface.r[2]);
    return lowest;
}

/// monta `params.ground_table` pelo VLM com o chão espelhado, com os momentos no CG seco. Precisa de `aero.init` antes.
/// As alturas vão da do avião parado no trem até 3 envergaduras acima; onde a malha girada encostaria no chão (cauda
/// baixa em α grande), vale a linha de cima
/// o profundor da diferença finita da tabela (rad)
const elevator_step = vec.V3{ 0.1, 0, 0 };

pub fn buildTable(params: *types.Params) vlm.Error!void {
    params.ground_table = .{};
    if (params.bref <= 0) return;
    const buffers: vlm.Buffers = .{ .panels = &work_panels, .matrix = &work_matrix, .pivots = &work_pivots, .gamma = &work_gamma };
    const cg = vec.v3(params.r_dry);
    const table = &params.ground_table;
    const width = types.GroundTable.alphas;
    const rest = restingHeight(params);
    for (lift_heights, 0..) |ratio, i| table.height[i] = rest + ratio * params.bref;
    for (table_alphas, 0..) |alpha_degrees, j| table.alpha[j] = alpha_degrees * std.math.pi / 180.0;
    for (table.alpha, 0..) |alpha, j| {
        const free = try vlm.groundCoefficients(params, table_grid, alpha, std.math.inf(f64), cg, buffers);
        const free_elevator = try vlm.groundCoefficientsWith(params, table_grid, alpha, std.math.inf(f64), cg, elevator_step, buffers);
        // a altura do CG sobre o chão com a origem na altura da tabela: a origem girada por α em torno do CG
        const turn = fmath.sincos(alpha);
        const origin_below_cg = turn.s * cg[0] - turn.c * cg[2]; // z girado da origem menos o do CG
        var row: usize = types.GroundTable.heights;
        while (row > 0) {
            row -= 1;
            const cell = row * width + j;
            const near = vlm.groundCoefficients(params, table_grid, alpha, table.height[row] + origin_below_cg, cg, buffers) catch |err| switch (err) {
                error.BelowGround, error.Singular => {
                    // encosta no chão: a linha de cima (a última sempre fecha: 3 envergaduras acima)
                    if (row + 1 < types.GroundTable.heights) {
                        table.lift[cell] = table.lift[cell + width];
                        table.moment[cell] = table.moment[cell + width];
                        table.lift_elevator[cell] = table.lift_elevator[cell + width];
                        table.moment_elevator[cell] = table.moment_elevator[cell + width];
                        if (table_alphas[j] == induced_alpha) table.induced[row] = table.induced[row + 1];
                    }
                    continue;
                },
                else => return err,
            };
            table.lift[cell] = near.CL - free.CL;
            table.moment[cell] = near.Cm - free.Cm;
            // o mesmo com o profundor: a diferença por radiano (o VLM é linear no comando para ângulos pequenos)
            const near_elevator = try vlm.groundCoefficientsWith(params, table_grid, alpha, table.height[row] + origin_below_cg, cg, elevator_step, buffers);
            table.lift_elevator[cell] = ((near_elevator.CL - free_elevator.CL) - table.lift[cell]) / elevator_step[0];
            table.moment_elevator[cell] = ((near_elevator.Cm - free_elevator.Cm) - table.moment[cell]) / elevator_step[0];
            if (table_alphas[j] == induced_alpha) table.induced[row] = (near.CDi / (near.CL * near.CL)) / (free.CDi / (free.CL * free.CL));
        }
    }
    table.n_height = types.GroundTable.heights;
    table.n_alpha = types.GroundTable.alphas;
}

/// o que a tabela dá numa altura da origem (m) e num α (rad): ΔC_L, o fator do induzido e ΔC_m
pub const Effect = struct {
    lift: f64 = 0,
    induced: f64 = 1,
    moment: f64 = 0,
    lift_elevator: f64 = 0, // por rad de δe
    moment_elevator: f64 = 0,
};

/// a interpolação linear da tabela em altura e em α, com os extremos segurados; tabela vazia: sem efeito
pub fn lookup(table: *const types.GroundTable, height: f64, alpha: f64) Effect {
    if (table.n_height < 2 or table.n_alpha < 2) return .{};
    const row = bracket(table.height[0..@intCast(table.n_height)], height);
    const column = bracket(table.alpha[0..@intCast(table.n_alpha)], alpha);
    const width = types.GroundTable.alphas;
    const corner = struct {
        fn blend(values: []const f64, low_row: usize, low_column: usize, row_fraction: f64, column_fraction: f64) f64 {
            const top = values[low_row * width + low_column] * (1 - column_fraction) + values[low_row * width + low_column + 1] * column_fraction;
            const bottom = values[(low_row + 1) * width + low_column] * (1 - column_fraction) + values[(low_row + 1) * width + low_column + 1] * column_fraction;
            return top * (1 - row_fraction) + bottom * row_fraction;
        }
    }.blend;
    return .{
        .lift = corner(&table.lift, row.index, column.index, row.fraction, column.fraction),
        .induced = table.induced[row.index] * (1 - row.fraction) + table.induced[row.index + 1] * row.fraction,
        .moment = corner(&table.moment, row.index, column.index, row.fraction, column.fraction),
        .lift_elevator = corner(&table.lift_elevator, row.index, column.index, row.fraction, column.fraction),
        .moment_elevator = corner(&table.moment_elevator, row.index, column.index, row.fraction, column.fraction),
    };
}

/// o trecho [index, index + 1] de `values` (crescente) que contém `query`, e a fração dentro dele (0 ou 1 fora)
fn bracket(values: []const f64, query: f64) struct { index: usize, fraction: f64 } {
    if (query <= values[0]) return .{ .index = 0, .fraction = 0 };
    const last = values.len - 1;
    if (query >= values[last]) return .{ .index = last - 1, .fraction = 1 };
    var index: usize = 0;
    while (index + 1 < last and values[index + 1] < query) index += 1;
    return .{ .index = index, .fraction = (query - values[index]) / (values[index + 1] - values[index]) };
}

const testing = std.testing;

test "McCormick: valores da fórmula e limites" {
    // h/b = 0,1: (1,6)² / (1 + 1,6²) = 2,56 / 3,56
    try testing.expectApproxEqAbs(2.56 / 3.56, mccormick(0.22, 2.2), 1e-12);
    // longe do chão o fator tende a 1; perto, a 0
    try testing.expect(mccormick(100.0, 2.0) > 0.9999);
    try testing.expect(mccormick(0.0, 2.0) < 0.01);
    // desligado: 1
    try testing.expectEqual(@as(f64, 1.0), factor(.off, 0.1, 2.0));
    try testing.expectEqual(mccormick(0.3, 2.0), factor(.mccormick, 0.3, 2.0));
}

test "imagem no VLM: a tabela da asa retangular sobe o C_L e corta o induzido perto do chão, e some longe" {
    var params: types.Params = .{};
    const span = 1.2;
    const chord = 0.2;
    const strips = 16;
    params.n_surf = strips;
    params.Sref = span * chord;
    params.cref = chord;
    params.bref = span;
    for (0..strips) |i| {
        const y0 = -0.5 * span + span * @as(f64, @floatFromInt(i)) / strips;
        const y1 = -0.5 * span + span * @as(f64, @floatFromInt(i + 1)) / strips;
        const side: i32 = if (0.5 * (y0 + y1) > 0) 1 else -1;
        params.surf[i] = .{ .r = .{ -0.25 * chord, 0.5 * (y0 + y1), 0 }, .S = (y1 - y0) * chord, .c = chord, .CLa = 4.5, .CL0 = 0.3, .side = side, .qa = .{ -0.25 * chord, if (side > 0) y0 else y1, 0 }, .qb = .{ -0.25 * chord, if (side > 0) y1 else y0, 0 } };
    }
    @import("../physics/aero.zig").init(&params);
    try buildTable(&params);
    const table = &params.ground_table;
    try testing.expectEqual(@as(i32, types.GroundTable.heights), table.n_height);
    const near = lookup(table, 0.1 * span, 4 * std.math.pi / 180.0);
    const far = lookup(table, 3.0 * span, 4 * std.math.pi / 180.0);
    try testing.expect(near.lift > 0.01 and near.induced < 0.85);
    try testing.expectApproxEqAbs(@as(f64, 0), far.lift, 2e-3);
    try testing.expectApproxEqAbs(@as(f64, 1), far.induced, 5e-3);
    // fora da grade segura os extremos; tabela vazia não faz nada
    try testing.expectEqual(lookup(table, 100.0, 0.0).lift, lookup(table, 3.0 * span, 0.0).lift);
    const empty: types.GroundTable = .{};
    try testing.expectEqual(@as(f64, 1), lookup(&empty, 0.1, 0.1).induced);
}
