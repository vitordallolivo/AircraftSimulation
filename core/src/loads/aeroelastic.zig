//! Aeroelasticidade estática de uma semiasa em faixas: divergência em torção e reversão do aileron.
//!
//! Cada estação torce θ_i em torno do eixo elástico. A torção vem dos momentos de todas as estações de fora, pela
//! matriz de flexibilidade da viga engastada na raiz, B_ij = ∫₀^{min(y_i, y_j)} dy/GJ. A sustentação de cada faixa é
//! L_j = q c_j Δs_j (a_j θ_j + c_lδ,j δ), e ela dá momento em torno do eixo elástico pelo braço e_j (o centro
//! aerodinâmico à frente do eixo, positivo para a frente), mais o c_mδ do comando:
//!
//!     (I − q B D) θ = q B m δ,    D = diag(a c Δs e),    m_j = c_j Δs_j (c_lδ,j e_j + c_j c_mδ,j)
//!
//! Divergência: a menor pressão dinâmica em que I − q B D fica singular, q_D = 1/λ_max(B D). Reversão: a pressão em
//! que o momento de rolamento do aileron, Σ y_j L_j, cai a zero com a asa torcida. O aileron sai da teoria do perfil
//! fino com o flap de corda c_f (Anderson, "Fundamentals of Aerodynamics", perfil fino com flap; Bisplinghoff, Ashley e
//! Halfman, "Aeroelasticity", divergência e reversão em faixas; a conferir nos PDFs):
//!
//!     cos θ_f = 2 c_f/c − 1,    c_lδ = 2 (π − θ_f + sen θ_f),    c_mδ = −½ sen θ_f (1 − cos θ_f)
const std = @import("std");
const fmath = @import("../math/fmath.zig");
const linalg = @import("../math/linalg.zig");
const scalar = @import("../optim/scalar.zig");

pub const max_stations = 48;

/// uma faixa da semiasa: posição do centro (m da raiz), largura (m), corda (m), c_lα (/rad), braço do centro
/// aerodinâmico à frente do eixo elástico (m), GJ (N·m²) e o comando ali (c_lδ e c_mδ por rad; 0 sem aileron)
pub const Station = extern struct {
    position: f64 = 0,
    width: f64 = 0,
    chord: f64 = 0,
    lift_slope: f64 = 0,
    offset: f64 = 0,
    torsional_stiffness: f64 = 0,
    control_lift: f64 = 0,
    control_moment: f64 = 0,
};

/// divergência e reversão: pressões dinâmicas (Pa; infinitas quando não existem) e velocidades na densidade pedida
pub const Aeroelastic = extern struct {
    divergence_pressure: f64 = 0,
    divergence_speed: f64 = 0,
    reversal_pressure: f64 = 0,
    reversal_speed: f64 = 0,
};

pub const Error = error{ TooManyStations, NoStations, NoStiffness, Singular };

const Matrix = [max_stations][max_stations]f64;

/// c_lδ e c_mδ (em 1/4 da corda, por rad) do flap de corda relativa `flap_ratio` = c_f/c, pelo perfil fino
pub fn flapDerivatives(flap_ratio: f64) struct { lift: f64, moment: f64 } {
    const angle = fmath.acos(2 * flap_ratio - 1);
    const sine = @sin(angle);
    return .{ .lift = 2 * (fmath.pi - angle + sine), .moment = -0.5 * sine * (1 - @cos(angle)) };
}

/// B_ij = ∫₀^{min(y_i, y_j)} dy/GJ, trapézio de 1/GJ da raiz (GJ da primeira estação até ela)
fn flexibility(stations: []const Station, out: *Matrix) Error!void {
    var compliance: [max_stations]f64 = undefined; // ∫₀^{y_i} dy/GJ
    var previous_position: f64 = 0;
    var previous_inverse: f64 = 0;
    for (stations, 0..) |station, i| {
        if (!(station.torsional_stiffness > 0)) return error.NoStiffness;
        const inverse = 1 / station.torsional_stiffness;
        const from = if (i == 0) inverse else previous_inverse;
        compliance[i] = (if (i == 0) 0 else compliance[i - 1]) + 0.5 * (station.position - previous_position) * (from + inverse);
        previous_position = station.position;
        previous_inverse = inverse;
    }
    for (0..stations.len) |i| {
        for (0..stations.len) |j| out[i][j] = compliance[@min(i, j)];
    }
}

/// a pressão dinâmica de divergência, 1/λ_max(B D); infinita se nenhum autovalor real é positivo
pub fn divergencePressure(stations: []const Station) Error!f64 {
    if (stations.len == 0) return error.NoStations;
    if (stations.len > max_stations) return error.TooManyStations;
    var matrix: Matrix = undefined;
    try flexibility(stations, &matrix);
    for (stations, 0..) |station, j| {
        const weight = station.lift_slope * station.chord * station.width * station.offset;
        for (0..stations.len) |i| matrix[i][j] *= weight;
    }
    var real: [max_stations]f64 = undefined;
    var imag: [max_stations]f64 = undefined;
    if (!linalg.generalEigen(max_stations, &matrix, stations.len, &real, &imag)) return error.Singular;
    var largest: f64 = 0;
    for (real[0..stations.len], imag[0..stations.len]) |value, imaginary| {
        if (@abs(imaginary) < 1e-12 * @abs(value) and value > largest) largest = value;
    }
    return if (largest > 0) 1 / largest else std.math.inf(f64);
}

/// o momento de rolamento do aileron com a asa torcida sobre o da asa rígida, na pressão dinâmica `pressure`
pub fn rollEffectiveness(stations: []const Station, pressure: f64) Error!f64 {
    if (stations.len == 0) return error.NoStations;
    if (stations.len > max_stations) return error.TooManyStations;
    var flexible: Matrix = undefined;
    try flexibility(stations, &flexible);
    var twist: [max_stations]f64 = [_]f64{0} ** max_stations;
    for (0..stations.len) |i| {
        for (stations, 0..) |station, j| {
            twist[i] += pressure * flexible[i][j] * station.chord * station.width * (station.control_lift * station.offset + station.chord * station.control_moment);
        }
    }
    // (I − q B D) θ = q B m (por unidade de δ)
    var system: Matrix = undefined;
    for (0..stations.len) |i| {
        for (stations, 0..) |station, j| {
            const weight = station.lift_slope * station.chord * station.width * station.offset;
            system[i][j] = (if (i == j) @as(f64, 1) else 0) - pressure * flexible[i][j] * weight;
        }
    }
    var pivots: [max_stations]usize = undefined;
    if (!linalg.luFactor(max_stations, &system, stations.len, &pivots)) return error.Singular;
    linalg.luSolve(max_stations, &system, stations.len, &pivots, &twist);
    var rigid: f64 = 0;
    var elastic: f64 = 0;
    for (stations, 0..) |station, j| {
        const lever = station.position * station.chord * station.width;
        rigid += lever * station.control_lift;
        elastic += lever * (station.control_lift + station.lift_slope * twist[j]);
    }
    return if (rigid != 0) elastic / rigid else 0;
}

/// a divergência e a reversão (por bisseção da eficiência do aileron entre 0 e a divergência ou `pressure_limit`), com
/// as velocidades na densidade `density`
pub fn analyze(stations: []const Station, density: f64, pressure_limit: f64) Error!Aeroelastic {
    const divergence = try divergencePressure(stations);
    var result: Aeroelastic = .{
        .divergence_pressure = divergence,
        .divergence_speed = @sqrt(2 * divergence / density),
        .reversal_pressure = std.math.inf(f64),
        .reversal_speed = std.math.inf(f64),
    };
    const top = 0.999 * @min(divergence, pressure_limit);
    const at_top = try rollEffectiveness(stations, top);
    var search = scalar.SignBisection.init(0, top, 1, at_top) orelse return result;
    while (search.interval.width() > 1e-6 * top) {
        const middle = search.middle();
        search.update(middle, try rollEffectiveness(stations, middle));
    }
    result.reversal_pressure = search.middle();
    result.reversal_speed = @sqrt(2 * result.reversal_pressure / density);
    return result;
}
