//! Momento próprio do comando (flape, profundor, elevon) no quarto de corda da faixa.
//!
//! Nas faixas, o comando só soma τ δ ao α da faixa (`physics/aero.zig`), e o Δc_l que isso dá age no ponto da
//! faixa (o quarto de corda). Na teoria do perfil fino o flape também muda o momento no quarto de corda:
//!
//!   Δc_l = 2 (π − θ_f + sen θ_f) δ        Δc_m,c/4 = −½ sen θ_f (1 − cos θ_f) δ        cos θ_f = 2 c_f/c − 1
//!
//! (Anderson, "Fundamentals of Aerodynamics", seção do flape na teoria do perfil fino; a conferir no PDF). Sem o
//! segundo termo, o elevon de uma asa voadora cabra bem menos do que deveria, porque o braço dele até o CG é curto.
//! A faixa guarda só τ, então θ_f sai de τ = k (1 − (θ_f − sen θ_f)/π), com k o fator empírico do τ (0,85 em
//! `aerosim/model/airfoil.py: flap_effectiveness`), e o Δc_m leva o mesmo k.
const std = @import("std");
const fm = @import("../math/fmath.zig");

/// θ_f (rad) do flape simples cujo τ (com o fator k) é `tau`: bisseção em [0, π], onde τ cai com θ_f
pub fn thetaOf(tau: f64, k: f64) f64 {
    const t = @min(@max(tau / k, 0.0), 1.0);
    var lo: f64 = 0.0;
    var hi: f64 = fm.pi;
    for (0..48) |_| {
        const mid = 0.5 * (lo + hi);
        const tm = 1.0 - (mid - @sin(mid)) / fm.pi;
        if (tm > t) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// dΔc_m,c/4 / dδ (por rad) da faixa com efetividade `tau`; 0 sem comando
pub fn cmDelta(tau: f64, k: f64) f64 {
    if (tau <= 0 or k <= 0) return 0.0;
    const th = thetaOf(tau, k);
    return -k * 0.5 * @sin(th) * (1.0 - @cos(th));
}

const testing = std.testing;

test "flape de 25 % e de 50 % da corda: θ_f e Δc_m do perfil fino" {
    // c_f/c = 0,25: cos θ_f = −0,5, θ_f = 2π/3; τ = 1 − (2π/3 − √3/2)/π = 0,6090; Δc_m = −½ (√3/2)(1,5) = −0,6495
    const tau25 = 1.0 - (2.0 * fm.pi / 3.0 - @sqrt(3.0) / 2.0) / fm.pi;
    try testing.expectApproxEqAbs(2.0 * fm.pi / 3.0, thetaOf(tau25, 1.0), 1e-9);
    try testing.expectApproxEqAbs(-0.6495190528, cmDelta(tau25, 1.0), 1e-8);
    // c_f/c = 0,5: θ_f = π/2; τ = 1 − (π/2 − 1)/π = 0,8183; Δc_m = −½; com k = 0,85 o τ e o Δc_m levam o fator
    const tau50 = 0.85 * (1.0 - (fm.pi / 2.0 - 1.0) / fm.pi);
    try testing.expectApproxEqAbs(-0.85 * 0.5, cmDelta(tau50, 0.85), 1e-8);
    try testing.expectEqual(@as(f64, 0.0), cmDelta(0.0, 0.85));
}
