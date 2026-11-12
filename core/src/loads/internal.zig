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

/// o giro de torção (rad) de cada estação, ∫ T/GJ da raiz engastada (`stiffness` = GJ, N·m²)
pub fn twist(positions: []const f64, torsion: []const f64, stiffness: []const f64, angle: []f64) Error!void {
    try check(positions, &.{ torsion.len, stiffness.len, angle.len });
    if (positions.len == 0) return;
    angle[0] = 0;
    for (1..positions.len) |i| {
        const step = positions[i] - positions[i - 1];
        angle[i] = angle[i - 1] + 0.5 * step * (torsion[i - 1] / stiffness[i - 1] + torsion[i] / stiffness[i]);
    }
}
