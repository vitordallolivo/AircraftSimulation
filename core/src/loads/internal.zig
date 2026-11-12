//! Esforços internos ao longo da envergadura de uma semiasa (ou de um tubo de cauda), da ponta para a raiz: cortante,
//! fletor e torsor, e daí a flecha e o giro de torção.
//!
//! As estações vão da raiz para a ponta, em `positions` (m ao longo da envergadura, a partir da raiz). Em cada estação
//! entram a sustentação (N, a do método de carga já no caso: VLM, linha sustentadora, faixas), a massa da estrutura ali
//! (kg; o alívio de inércia, que puxa para baixo com n g) e o momento de torção em torno do eixo elástico (N·m):
//!
//!     V(y_i) = Σ_{j≥i} (L_j − n m_j g)
//!     M(y_i) = Σ_{j>i} (L_j − n m_j g)(y_j − y_i)
//!     T(y_i) = Σ_{j≥i} t_j
//!
//! A flecha sai por dupla integração trapezoidal de M/EI, e o giro por ∫T/GJ, as duas com a raiz engastada (Megson,
//! "Aircraft Structures for Engineering Students", flexão e torção de vigas; a conferir no PDF).
const std = @import("std");

const gravity = 9.80665;

pub const Error = error{ SizeMismatch, NotOrdered };

/// confere os tamanhos e a ordem da raiz para a ponta
fn check(positions: []const f64, others: []const usize) Error!void {
    for (others) |len| if (len < positions.len) return error.SizeMismatch;
    for (1..positions.len) |i| if (positions[i] < positions[i - 1]) return error.NotOrdered;
}

/// a massa `total` (kg) repartida pelas estações na proporção de `areas` (a estrutura acompanha a corda), em `out`
pub fn shareByArea(total: f64, areas: []const f64, out: []f64) void {
    var sum: f64 = 0;
    for (areas) |area| sum += area;
    for (areas, out[0..areas.len]) |area, *mass| mass.* = if (sum > 0) total * area / sum else 0;
}

/// cortante (N), fletor (N·m) e torsor (N·m) em cada estação, com o fator de carga `load_factor` no alívio de inércia;
/// `torques` pode ser vazio (sem torção)
pub fn efforts(positions: []const f64, lifts: []const f64, masses: []const f64, torques: []const f64, load_factor: f64, shear: []f64, bending: []f64, torsion: []f64) Error!void {
    try check(positions, &.{ lifts.len, masses.len, shear.len, bending.len, torsion.len });
    if (torques.len != 0 and torques.len < positions.len) return error.SizeMismatch;
    var net_force: f64 = 0;
    var net_moment: f64 = 0; // Σ F_j y_j das estações de fora, para M(y_i) = Σ F_j y_j − y_i Σ F_j
    var twisting: f64 = 0;
    var i = positions.len;
    while (i > 0) {
        i -= 1;
        const net = lifts[i] - load_factor * masses[i] * gravity;
        bending[i] = net_moment - positions[i] * net_force;
        net_force += net;
        net_moment += net * positions[i];
        twisting += if (torques.len != 0) torques[i] else 0;
        shear[i] = net_force;
        torsion[i] = twisting;
    }
}

/// a inclinação (rad) e a flecha (m) de cada estação pela dupla integração trapezoidal de M/EI, raiz engastada
/// (`stiffness` = EI em cada estação, N·m²)
pub fn deflection(positions: []const f64, bending: []const f64, stiffness: []const f64, slope: []f64, displacement: []f64) Error!void {
    try check(positions, &.{ bending.len, stiffness.len, slope.len, displacement.len });
    if (positions.len == 0) return;
    slope[0] = 0;
    displacement[0] = 0;
    for (1..positions.len) |i| {
        const step = positions[i] - positions[i - 1];
        slope[i] = slope[i - 1] + 0.5 * step * (bending[i - 1] / stiffness[i - 1] + bending[i] / stiffness[i]);
        displacement[i] = displacement[i - 1] + 0.5 * step * (slope[i - 1] + slope[i]);
    }
}

/// o giro de torção (rad) de cada estação, ∫ T/GJ da raiz engastada (`stiffness` = GJ, N·m²), com o torsor de cada
/// trecho constante (os torques são concentrados nas estações)
pub fn twist(positions: []const f64, torsion: []const f64, stiffness: []const f64, angle: []f64) Error!void {
    try check(positions, &.{ torsion.len, stiffness.len, angle.len });
    if (positions.len == 0) return;
    angle[0] = 0;
    for (1..positions.len) |i| {
        const step = positions[i] - positions[i - 1];
        // entre as estações i − 1 e i o torsor é o das estações de i para fora, T(y_i): constante no trecho
        angle[i] = angle[i - 1] + 0.5 * step * torsion[i] * (1 / stiffness[i - 1] + 1 / stiffness[i]);
    }
}

// ------------------------------------------------------------------ testes
const testing = std.testing;
const plot = @import("../util/plot.zig");

const stations = 201;

/// uma viga de 1 m com a carga `per_length` (N/m) repartida pelas estações (meia nas pontas, como no trapézio)
fn uniformBeam(per_length: f64, positions: *[stations]f64, loads: *[stations]f64) void {
    const step = 1.0 / @as(f64, stations - 1);
    for (positions, loads, 0..) |*position, *load, i| {
        position.* = step * @as(f64, @floatFromInt(i));
        load.* = per_length * step * (if (i == 0 or i == stations - 1) @as(f64, 0.5) else 1);
    }
}

test "esforços: viga em balanço com carga uniforme dá V = wL, M = wL²/2 na raiz e flecha wL⁴/(8 EI) na ponta" {
    var positions: [stations]f64 = undefined;
    var lifts: [stations]f64 = undefined;
    uniformBeam(100, &positions, &lifts);
    const masses = [_]f64{0} ** stations;
    var shear: [stations]f64 = undefined;
    var bending: [stations]f64 = undefined;
    var torsion: [stations]f64 = undefined;
    try efforts(&positions, &lifts, &masses, &.{}, 1, &shear, &bending, &torsion);
    // Megson, viga em balanço: V(0) = w L = 100 N; M(0) = w L²/2 = 50 N·m
    try testing.expectApproxEqRel(@as(f64, 100), shear[0], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 50), bending[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0), bending[stations - 1], 1e-12);
    const stiffness = [_]f64{1000} ** stations;
    var slope: [stations]f64 = undefined;
    var displacement: [stations]f64 = undefined;
    try deflection(&positions, &bending, &stiffness, &slope, &displacement);
    // δ = w L⁴/(8 EI) = 100/8000 = 0,0125 m; θ = w L³/(6 EI) = 0,016667
    try testing.expectApproxEqRel(@as(f64, 0.0125), displacement[stations - 1], 1e-3);
    try testing.expectApproxEqRel(@as(f64, 100.0 / 6000.0), slope[stations - 1], 1e-3);
    try plot.fromTest("esforcos_balanco", .{ .title = "Viga em balanço, carga uniforme", .x_label = "y (m)", .y_label = "V (N), M (N·m), flecha (mm)", .series = &.{
        .{ .label = "cortante", .x = &positions, .y = &shear },
        .{ .label = "fletor", .x = &positions, .y = &bending },
        .{ .label = "flecha × 1000", .x = &positions, .y = &scaled(displacement, 1000) },
    } });
}

/// uma cópia de `values` vezes `factor` (para o gráfico)
fn scaled(values: [stations]f64, factor: f64) [stations]f64 {
    var out = values;
    for (&out) |*value| value.* *= factor;
    return out;
}

test "esforços: o alívio de inércia que iguala a sustentação zera tudo, e o torsor uniforme dá giro tL²/(2 GJ)" {
    var positions: [stations]f64 = undefined;
    var lifts: [stations]f64 = undefined;
    uniformBeam(100, &positions, &lifts);
    var masses: [stations]f64 = undefined;
    for (&masses, lifts) |*mass, lift| mass.* = lift / (2.5 * gravity);
    var torques: [stations]f64 = undefined;
    uniformBeam(4, &positions, &torques);
    var shear: [stations]f64 = undefined;
    var bending: [stations]f64 = undefined;
    var torsion: [stations]f64 = undefined;
    try efforts(&positions, &lifts, &masses, &torques, 2.5, &shear, &bending, &torsion);
    for (shear, bending) |force, moment| {
        try testing.expectApproxEqAbs(@as(f64, 0), force, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), moment, 1e-9);
    }
    try testing.expectApproxEqRel(@as(f64, 4), torsion[0], 1e-12);
    const stiffness = [_]f64{50} ** stations;
    var angle: [stations]f64 = undefined;
    try twist(&positions, &torsion, &stiffness, &angle);
    // θ = t L²/(2 GJ) = 4/100 = 0,04 rad
    try testing.expectApproxEqRel(@as(f64, 0.04), angle[stations - 1], 1e-3);
}

test "esforços: tamanhos que não batem e estações fora de ordem dão erro" {
    var out: [3]f64 = undefined;
    try testing.expectError(error.SizeMismatch, efforts(&.{ 0, 1, 2 }, &.{ 1, 1 }, &.{ 0, 0, 0 }, &.{}, 1, &out, &out, &out));
    try testing.expectError(error.NotOrdered, efforts(&.{ 0, 2, 1 }, &.{ 1, 1, 1 }, &.{ 0, 0, 0 }, &.{}, 1, &out, &out, &out));
}
