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
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const collision = @import("../collision/collision.zig");
const V3 = vec.V3;

/// o tubo da esteira como forma de colisão: raio pela contração (sem tração: o cilindro do raio da hélice)
pub const TubeShape = struct {
    R: f64,
    V: f64,
    w0: f64,

    fn radius(ctx: *const anyopaque, distance: f64) f64 {
        const self: *const TubeShape = @ptrCast(@alignCast(ctx));
        return if (self.w0 > 0) radiusAt(self.R, self.V, self.w0, distance) else self.R;
    }

    /// `shape` precisa viver enquanto o tubo for usado. axis_fwd: eixo de tração (o tubo vai no sentido oposto)
    pub fn tube(self: *const TubeShape, hub: V3, axis_fwd: V3, length: f64) collision.Tube {
        return .{ .origin = hub, .axis = -axis_fwd, .R = self.R, .length = length, .ctx = self, .radiusFn = radius };
    }
};

/// a forma do tubo de um motor com tração `thrust` e velocidade axial `axial_speed` (w0 da teoria do momento; T ≤ 0: cilindro)
pub fn shape(thrust: f64, axial_speed: f64, radius: f64, rho: f64) TubeShape {
    return .{ .R = radius, .V = @max(axial_speed, 0.0), .w0 = diskInduced(thrust, axial_speed, radius, rho) };
}

/// w0 da teoria do momento (m/s). axial_speed: velocidade axial através do disco (≥ 0); T ≤ 0: sem esteira
pub fn diskInduced(thrust: f64, axial_speed: f64, radius: f64, rho: f64) f64 {
    if (thrust <= 0 or radius <= 0 or rho <= 0) return 0;
    const disk_area = fmath.pi * radius * radius;
    const speed_in = @max(axial_speed, 0.0);
    return -0.5 * speed_in + @sqrt(0.25 * speed_in * speed_in + thrust / (2.0 * rho * disk_area));
}

/// w(x) no eixo, com x = `distance` a partir do disco (positivo para trás)
pub fn axialAt(w0: f64, radius: f64, distance: f64) f64 {
    return w0 * (1.0 + distance / @sqrt(distance * distance + radius * radius));
}

/// raio do tubo a `distance` do disco (continuidade)
pub fn radiusAt(radius: f64, axial_speed: f64, w0: f64, distance: f64) f64 {
    const speed_in = @max(axial_speed, 0.0);
    const speed_out = speed_in + axialAt(w0, radius, distance);
    if (speed_out <= 1e-9) return radius;
    return radius * @sqrt((speed_in + w0) / speed_out);
}

/// Ω0 (rad/s) do giro de corpo rígido no disco a partir do torque
pub fn swirlRate(torque: f64, axial_speed: f64, w0: f64, radius: f64, rho: f64) f64 {
    const speed_through = @max(axial_speed, 0.0) + w0;
    if (speed_through <= 1e-9 or radius <= 0 or rho <= 0) return 0;
    return 2.0 * torque / (fmath.pi * rho * speed_through * radius * radius * radius * radius);
}

/// a esteira num ponto: velocidade axial a mais, giro, raio do tubo ali e se o ponto está dentro
pub const Point = struct {
    axial: f64 = 0, // velocidade a mais do ar, para trás ao longo do eixo (m/s)
    swirl: V3 = vec.zero, // velocidade do ar do giro (m/s, corpo)
    R: f64 = 0, // raio do tubo nessa posição
    inside: bool = false,
};

/// a esteira de um motor no ponto `offset = r_ponto − r_cubo` (corpo); eT: eixo de tração (para a frente)
pub fn at(thrust: f64, torque: f64, axial_speed: f64, radius: f64, rho: f64, sense: f64, eT: V3, offset: V3, use_axial: bool, use_swirl: bool) Point {
    const w0 = diskInduced(thrust, axial_speed, radius, rho);
    if (w0 <= 0) return .{};
    const distance = -vec.dot(offset, eT); // para trás do disco: x > 0
    const rad = offset + eT * vec.splat(distance); // componente perpendicular ao eixo
    const rr = vec.norm(rad);
    const Rx = radiusAt(radius, axial_speed, w0, distance);
    if (rr > Rx) return .{ .R = Rx };
    var out = Point{ .R = Rx, .inside = true };
    if (use_axial) out.axial = axialAt(w0, radius, distance);
    if (use_swirl and distance > 0) {
        const omega = swirlRate(torque, axial_speed, w0, radius, rho) * (radius / Rx) * (radius / Rx);
        // ar girando com a hélice: ω_esteira = sense Ω eT; v = ω × r
        out.swirl = vec.cross(eT * vec.splat(sense * omega), rad);
    }
    return out;
}

const testing = std.testing;

test "momento: T = 2ρA w0 (V + w0), estático w0 = √(T/(2ρA))" {
    const radius: f64 = 0.19;
    const rho: f64 = 1.225;
    const disk_area = fmath.pi * radius * radius;
    for ([_]f64{ 0, 5, 12, 20 }) |axial_speed| {
        const w0 = diskInduced(30.0, axial_speed, radius, rho);
        try testing.expectApproxEqRel(30.0, 2.0 * rho * disk_area * w0 * (axial_speed + w0), 1e-12);
    }
    try testing.expectApproxEqRel(@sqrt(30.0 / (2.0 * rho * disk_area)), diskInduced(30.0, 0, radius, rho), 1e-12);
    try testing.expectEqual(@as(f64, 0), diskInduced(0, 10, radius, rho));
    try testing.expectEqual(@as(f64, 0), diskInduced(-3, 10, radius, rho));
}

test "eixo: w(0) = w0, w(∞) → 2 w0, w(−∞) → 0; contração por continuidade" {
    const w0: f64 = 4.0;
    const radius: f64 = 0.2;
    try testing.expectApproxEqAbs(w0, axialAt(w0, radius, 0), 1e-12);
    try testing.expectApproxEqRel(2.0 * w0, axialAt(w0, radius, 1e4), 1e-6);
    try testing.expect(axialAt(w0, radius, -1e4) < 1e-6);
    const axial_speed: f64 = 10.0;
    const Rx = radiusAt(radius, axial_speed, w0, 5.0);
    try testing.expectApproxEqRel((axial_speed + w0) * radius * radius, (axial_speed + axialAt(w0, radius, 5.0)) * Rx * Rx, 1e-12);
    try testing.expect(Rx < radius);
}

test "giro: o fluxo de momento angular no disco é o torque" {
    const radius: f64 = 0.19;
    const rho: f64 = 1.225;
    const axial_speed: f64 = 8.0;
    const torque: f64 = 1.3;
    const w0 = diskInduced(30.0, axial_speed, radius, rho);
    const omega = swirlRate(torque, axial_speed, w0, radius, rho);
    // ∫0^R ρ (V + w0) (Ω r) r 2π r dr, numérico
    var flux: f64 = 0;
    const steps: usize = 4000;
    const dr = radius / @as(f64, @floatFromInt(steps));
    for (0..steps) |k| {
        const position = (@as(f64, @floatFromInt(k)) + 0.5) * dr;
        flux += rho * (axial_speed + w0) * omega * position * position * 2.0 * fmath.pi * position * dr;
    }
    try testing.expectApproxEqRel(torque, flux, 1e-6);
}

test "ponto: fora do tubo nada; sentido inverte o giro; à frente sem giro" {
    const eT = V3{ 1, 0, 0 };
    const back = V3{ -0.5, 0.1, 0 }; // 0,5 m atrás, 0,1 m à direita
    const clockwise = at(30, 1.2, 10, 0.19, 1.225, 1, eT, back, true, true);
    const counter = at(30, 1.2, 10, 0.19, 1.225, -1, eT, back, true, true);
    try testing.expect(clockwise.inside and clockwise.axial > 0);
    try testing.expectApproxEqAbs(clockwise.swirl[2], -counter.swirl[2], 1e-12);
    try testing.expect(@abs(clockwise.swirl[2]) > 0);
    const out = at(30, 1.2, 10, 0.19, 1.225, 1, eT, V3{ -0.5, 0.5, 0 }, true, true);
    try testing.expect(!out.inside and out.axial == 0);
    const ahead = at(30, 1.2, 10, 0.19, 1.225, 1, eT, V3{ 0.1, 0.05, 0 }, true, true);
    try testing.expect(ahead.inside and ahead.axial > 0 and ahead.axial < diskInduced(30, 10, 0.19, 1.225));
    try testing.expectEqual(@as(f64, 0), vec.norm(ahead.swirl));
    // horário visto de trás, ponto à direita (+y): o ar desce na direita? ω = +x, r = +y ⇒ ω × r = +z (para baixo)
    try testing.expect(clockwise.swirl[2] > 0);
}
