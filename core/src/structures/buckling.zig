//! Flambagem do chapeado e da alma, e quantas nervuras um vão precisa para o chapeado não flambar.
//!
//! Placa ortotrópica simplesmente apoiada sob compressão na direção 1, de lado `a` na compressão (o vão entre
//! nervuras) e `b` na largura (Jones, "Mechanics of Composite Materials", flambagem de placa ortotrópica; a conferir no
//! PDF):
//!
//!     D11 = E1 t³/(12 (1 − ν12 ν21)),  D22 = E2 t³/(12 (1 − ν12 ν21)),  D12 = ν21 D11,  D66 = G12 t³/12
//!     σ_cr = π²/(t b²) min_m [D11 (m b/a)² + 2 (D12 + 2 D66) + D22 (a/(m b))²]
//!
//! Painel curvo de raio R (o chapeado do bordo de ataque), casca cilíndrica ortotrópica de Donnell, com o fator de
//! redução `knockdown` dado pelo usuário (a conferir no PDF):
//!
//!     σ_cr = k_d min_{m,n} [(D11 λ⁴ + 2 (D12 + 2 D66) λ² μ² + D22 μ⁴)/(t λ²) + (λ²/R²)/(s22 λ⁴ + (s66 + 2 s12) λ² μ² + s11 μ⁴)]
//!
//! com λ = m π/a, μ = n π/b e s_ij as flexibilidades de membrana da placa (por espessura). Alma em cisalhamento
//! (Timoshenko e Gere, "Theory of Elastic Stability", placa sob cisalhamento; a conferir no PDF):
//!
//!     τ_cr = k π² E/(12 (1 − ν²)) (t/h)²,  k = 5,34 + 4 (h/a)²  (a ≥ h)
const std = @import("std");
const fmath = @import("../math/fmath.zig");

/// um material ortotrópico de placa: módulos na direção 1 (a da compressão) e 2, cisalhamento e Poisson ν12 (Pa)
pub const Orthotropic = extern struct {
    modulus_1: f64 = 0,
    modulus_2: f64 = 0,
    shear_modulus: f64 = 0,
    poisson_12: f64 = 0.3,
};

/// quantas meias-ondas tentar em cada direção
const max_waves = 12;

/// as rigidezes de flexão D11, D22, D12 e D66 da placa de espessura `thickness`
fn bendingStiffness(material: Orthotropic, thickness: f64) struct { d11: f64, d22: f64, d12: f64, d66: f64, poisson_21: f64 } {
    const poisson_21 = material.poisson_12 * material.modulus_2 / material.modulus_1;
    const cube = thickness * thickness * thickness;
    const denominator = 12 * (1 - material.poisson_12 * poisson_21);
    const d11 = material.modulus_1 * cube / denominator;
    return .{ .d11 = d11, .d22 = material.modulus_2 * cube / denominator, .d12 = poisson_21 * d11, .d66 = material.shear_modulus * cube / 12, .poisson_21 = poisson_21 };
}

/// σ_cr (Pa) da placa plana `length` (a, na compressão) × `width` (b), espessura `thickness`
pub fn flatPlate(material: Orthotropic, length: f64, width: f64, thickness: f64) f64 {
    const stiffness = bendingStiffness(material, thickness);
    var lowest = std.math.inf(f64);
    for (1..max_waves + 1) |waves| {
        const ratio = @as(f64, @floatFromInt(waves)) * width / length;
        const value = stiffness.d11 * ratio * ratio + 2 * (stiffness.d12 + 2 * stiffness.d66) + stiffness.d22 / (ratio * ratio);
        lowest = @min(lowest, value);
    }
    return fmath.pi * fmath.pi / (thickness * width * width) * lowest;
}

/// σ_cr (Pa) do painel curvo de raio `radius` (Donnell ortotrópico), com o fator de redução `knockdown`
pub fn curvedPanel(material: Orthotropic, length: f64, width: f64, thickness: f64, radius: f64, knockdown: f64) f64 {
    const stiffness = bendingStiffness(material, thickness);
    // flexibilidades de membrana (s = A⁻¹ com A = Q t): s11 = 1/(E1 t), s22 = 1/(E2 t), s12 = −ν12/(E1 t), s66 = 1/(G t)
    const s11 = 1 / (material.modulus_1 * thickness);
    const s22 = 1 / (material.modulus_2 * thickness);
    const s12 = -material.poisson_12 / (material.modulus_1 * thickness);
    const s66 = 1 / (material.shear_modulus * thickness);
    var lowest = std.math.inf(f64);
    for (1..max_waves + 1) |m| {
        const lambda = @as(f64, @floatFromInt(m)) * fmath.pi / length;
        const lambda2 = lambda * lambda;
        for (1..max_waves + 1) |n| {
            const mu = @as(f64, @floatFromInt(n)) * fmath.pi / width;
            const mu2 = mu * mu;
            const plate = (stiffness.d11 * lambda2 * lambda2 + 2 * (stiffness.d12 + 2 * stiffness.d66) * lambda2 * mu2 + stiffness.d22 * mu2 * mu2) / (thickness * lambda2);
            const membrane = (lambda2 / (radius * radius)) / (thickness * (s22 * lambda2 * lambda2 + (s66 + 2 * s12) * lambda2 * mu2 + s11 * mu2 * mu2));
            lowest = @min(lowest, plate + membrane);
        }
    }
    return knockdown * lowest;
}

/// o raio do arco de corda `chord` e flecha `rise`: R = c²/(8 s) + s/2
pub fn arcRadius(chord: f64, rise: f64) f64 {
    return chord * chord / (8 * rise) + 0.5 * rise;
}

/// τ_cr (Pa) da alma de altura `height`, vão `length` e espessura `thickness`, com o E equivalente √(E1 E2)
pub fn webShear(material: Orthotropic, height: f64, length: f64, thickness: f64) f64 {
    const long = @max(length, height);
    const short = @min(length, height);
    const coefficient = 5.34 + 4 * (short / long) * (short / long);
    const modulus = @sqrt(material.modulus_1 * material.modulus_2);
    const ratio = thickness / short;
    return coefficient * fmath.pi * fmath.pi * modulus / (12 * (1 - material.poisson_12 * material.poisson_12)) * ratio * ratio;
}

/// quantas nervuras a mais um vão `span` precisa para a placa plana `width` × `thickness` aguentar `stress` (Pa): o
/// menor número de divisões iguais em que σ_cr ≥ `stress`; null se nem `max_ribs` resolve
pub fn ribsNeeded(material: Orthotropic, span: f64, width: f64, thickness: f64, stress: f64, max_ribs: usize) ?usize {
    for (0..max_ribs + 1) |extra| {
        const length = span / @as(f64, @floatFromInt(extra + 1));
        if (flatPlate(material, length, width, thickness) >= stress) return extra;
    }
    return null;
}
