//! Esteira da hélice por disco atuador (modificador `esteira.disco`).
//!
//! Por motor, a partir da tração T e do torque Q do instante (carga uniforme no disco de raio R):
//!
//!  1. Velocidade induzida no disco — teoria do momento de Rankine–Froude:
//!       T = 2 ρ A w0 (V + w0)   ⇒   w0 = −V/2 + √(V²/4 + T/(2ρA)),   A = πR²
//!     (McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics*, teoria do momento da hélice;
//!      Glauert, "Airplane Propellers", em Durand, *Aerodynamic Theory* vol. IV, 1935)
//!  2. Desenvolvimento ao longo do eixo (disco com carga uniforme = cilindro de vórtices semi-infinito),
//!     x medido a partir do disco, positivo para trás:
//!       w(x) = w0 (1 + x / √(x² + R²))        w(0) = w0, w(∞) = 2 w0, w(−∞) = 0
//!     (resultado clássico do disco atuador, usado por McCormick, *Aerodynamics of V/STOL Flight*, e na
//!      revisão de Veldhuis, ICAS 2004 / tese TU Delft 2005, para a posição da asa na esteira)
//!  3. Contração do tubo por continuidade: (V + w(x)) R(x)² = (V + w0) R²
//!  4. Giro (só atrás do disco): balanço de quantidade de movimento angular — o fluxo de momento angular
//!     que atravessa o disco é o torque, Q = ∫ ρ (V + w0) v_t r dA (Glauert, op. cit.). Com rotação de corpo
//!     rígido v_t = Ω r (hipótese desta implementação):
//!       Ω0 = 2Q / (π ρ (V + w0) R⁴),   e conservando o momento angular no tubo que contrai: Ω(x) = Ω0 (R/R(x))²
//!     O giro tem o sentido da rotação da hélice (`sense`: +1 horário visto de trás).
//!
//! Limites desta versão (ver README.md):
//!   - a velocidade axial é a do eixo, aplicada igual em toda a seção do tubo (perfil "chapéu");
//!   - o tubo segue o eixo do motor (não é desviado pelo α nem pela asa);
//!   - sem interação hélice → hélice e asa → hélice.
const std = @import("std");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

/// w0 da teoria do momento (m/s). V: velocidade axial através do disco (≥ 0); T ≤ 0: sem esteira
pub fn diskInduced(T: f64, V: f64, R: f64, rho: f64) f64 {
    if (T <= 0 or R <= 0 or rho <= 0) return 0;
    const A = fm.pi * R * R;
    const Vp = @max(V, 0.0);
    return -0.5 * Vp + @sqrt(0.25 * Vp * Vp + T / (2.0 * rho * A));
}

/// w(x) no eixo, x a partir do disco (positivo para trás)
pub fn axialAt(w0: f64, R: f64, x: f64) f64 {
    return w0 * (1.0 + x / @sqrt(x * x + R * R));
}

/// raio do tubo em x (continuidade)
pub fn radiusAt(R: f64, V: f64, w0: f64, x: f64) f64 {
    const Vp = @max(V, 0.0);
    const u = Vp + axialAt(w0, R, x);
    if (u <= 1e-9) return R;
    return R * @sqrt((Vp + w0) / u);
}

/// Ω0 (rad/s) do giro de corpo rígido no disco a partir do torque
pub fn swirlRate(Q: f64, V: f64, w0: f64, R: f64, rho: f64) f64 {
    const u = @max(V, 0.0) + w0;
    if (u <= 1e-9 or R <= 0 or rho <= 0) return 0;
    return 2.0 * Q / (fm.pi * rho * u * R * R * R * R);
}

pub const Point = struct {
    axial: f64 = 0, // velocidade a mais do ar, para trás ao longo do eixo (m/s)
    swirl: V3 = vec.zero, // velocidade do ar do giro (m/s, corpo)
    R: f64 = 0, // raio do tubo nessa posição
    inside: bool = false,
};

/// a esteira de um motor no ponto `d = r_ponto − r_cubo` (corpo); eT: eixo de tração (para a frente)
pub fn at(T: f64, Q: f64, V: f64, R: f64, rho: f64, sense: f64, eT: V3, d: V3, use_axial: bool, use_swirl: bool) Point {
    const w0 = diskInduced(T, V, R, rho);
    if (w0 <= 0) return .{};
    const x = -vec.dot(d, eT); // para trás do disco: x > 0
    const rad = d + eT * vec.splat(x); // componente perpendicular ao eixo
    const rr = vec.norm(rad);
    const Rx = radiusAt(R, V, w0, x);
    if (rr > Rx) return .{ .R = Rx };
    var o = Point{ .R = Rx, .inside = true };
    if (use_axial) o.axial = axialAt(w0, R, x);
    if (use_swirl and x > 0) {
        const Om = swirlRate(Q, V, w0, R, rho) * (R / Rx) * (R / Rx);
        // ar girando com a hélice: ω_esteira = sense Ω eT; v = ω × r
        o.swirl = vec.cross(eT * vec.splat(sense * Om), rad);
    }
    return o;
}

const testing = std.testing;

test "momento: T = 2ρA w0 (V + w0), estático w0 = √(T/(2ρA))" {
    const R: f64 = 0.19;
    const rho: f64 = 1.225;
    const A = fm.pi * R * R;
    for ([_]f64{ 0, 5, 12, 20 }) |V| {
        const w0 = diskInduced(30.0, V, R, rho);
        try testing.expectApproxEqRel(30.0, 2.0 * rho * A * w0 * (V + w0), 1e-12);
    }
    try testing.expectApproxEqRel(@sqrt(30.0 / (2.0 * rho * A)), diskInduced(30.0, 0, R, rho), 1e-12);
    try testing.expectEqual(@as(f64, 0), diskInduced(0, 10, R, rho));
    try testing.expectEqual(@as(f64, 0), diskInduced(-3, 10, R, rho));
}

test "eixo: w(0) = w0, w(∞) → 2 w0, w(−∞) → 0; contração por continuidade" {
    const w0: f64 = 4.0;
    const R: f64 = 0.2;
    try testing.expectApproxEqAbs(w0, axialAt(w0, R, 0), 1e-12);
    try testing.expectApproxEqRel(2.0 * w0, axialAt(w0, R, 1e4), 1e-6);
    try testing.expect(axialAt(w0, R, -1e4) < 1e-6);
    const V: f64 = 10.0;
    const Rx = radiusAt(R, V, w0, 5.0);
    try testing.expectApproxEqRel((V + w0) * R * R, (V + axialAt(w0, R, 5.0)) * Rx * Rx, 1e-12);
    try testing.expect(Rx < R);
}

test "giro: o fluxo de momento angular no disco é o torque" {
    const R: f64 = 0.19;
    const rho: f64 = 1.225;
    const V: f64 = 8.0;
    const Q: f64 = 1.3;
    const w0 = diskInduced(30.0, V, R, rho);
    const Om = swirlRate(Q, V, w0, R, rho);
    // ∫0^R ρ (V + w0) (Ω r) r 2π r dr, numérico
    var s: f64 = 0;
    const n: usize = 4000;
    const dr = R / @as(f64, @floatFromInt(n));
    for (0..n) |k| {
        const r = (@as(f64, @floatFromInt(k)) + 0.5) * dr;
        s += rho * (V + w0) * Om * r * r * 2.0 * fm.pi * r * dr;
    }
    try testing.expectApproxEqRel(Q, s, 1e-6);
}

test "ponto: fora do tubo nada; sentido inverte o giro; à frente sem giro" {
    const eT = V3{ 1, 0, 0 };
    const back = V3{ -0.5, 0.1, 0 }; // 0,5 m atrás, 0,1 m à direita
    const a = at(30, 1.2, 10, 0.19, 1.225, 1, eT, back, true, true);
    const b = at(30, 1.2, 10, 0.19, 1.225, -1, eT, back, true, true);
    try testing.expect(a.inside and a.axial > 0);
    try testing.expectApproxEqAbs(a.swirl[2], -b.swirl[2], 1e-12);
    try testing.expect(@abs(a.swirl[2]) > 0);
    const out = at(30, 1.2, 10, 0.19, 1.225, 1, eT, V3{ -0.5, 0.5, 0 }, true, true);
    try testing.expect(!out.inside and out.axial == 0);
    const ahead = at(30, 1.2, 10, 0.19, 1.225, 1, eT, V3{ 0.1, 0.05, 0 }, true, true);
    try testing.expect(ahead.inside and ahead.axial > 0 and ahead.axial < diskInduced(30, 10, 0.19, 1.225));
    try testing.expectEqual(@as(f64, 0), vec.norm(ahead.swirl));
    // horário visto de trás, ponto à direita (+y): o ar desce na direita? ω = +x, r = +y ⇒ ω × r = +z (para baixo)
    try testing.expect(a.swirl[2] > 0);
}
