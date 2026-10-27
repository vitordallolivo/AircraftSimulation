//! Interferência entre duas asas ligadas (tandem, biplano) no modelo de faixas.
//!
//! As faixas tratam cada painel sozinho: a asa de trás de um tandem não sente o downwash da da frente, e as duas
//! asas de um biplano não se induzem. A linha sustentadora (loads/llt.zig) resolve isso montando e resolvendo o
//! sistema das circulações de todos os painéis; aqui entra só a parte entre as duas asas, numa passada, sem sistema:
//!
//!   1. cada painel j das duas asas tem a circulação da sua própria carga de faixa (Kutta–Joukowski,
//!      ρ V Γ = ½ ρ V² c η c_l, o mesmo k_i de llt.zig):  Γ_j = ½ V_j c_j η_j C_L,j
//!      com o α do painel sem esta interferência (com os outros modificadores, o downwash empírico e os comandos);
//!   2. no ponto de controle i de uma asa, a velocidade induzida pelas ferraduras da OUTRA asa:
//!      w_i = Σ_j Γ_j w_ij,   w_ij = ferradura de Γ = 1 de j (segmento ligado + pernas ao longo do escoamento),
//!      Biot–Savart de segmento reto (Katz e Plotkin, "Low-Speed Aerodynamics", 2ª ed., cap. 10, como em llt.zig;
//!      números das equações a conferir no PDF), com o núcleo de Scully entre superfícies (llt.core_frac);
//!   3. o painel i vê v = V_ar + ω × r − ganho · w_i: outro α e a força girada (o arrasto induzido da interferência
//!      sai da inclinação da sustentação, como na linha sustentadora).
//!
//! A própria asa fica de fora (a faixa já tem o seu C_Di = C_L²/(π e AR)). Por ser uma passada, a de trás não
//! devolve o efeito para a da frente pelo α dela (no tandem a asa da frente quase não sente a de trás; no biplano a
//! influência é mútua e a passada é a primeira iteração do sistema). Com o modelo da linha sustentadora no voo
//! (`aero_model` ≠ 0) não faz nada: lá a interferência já está no sistema.
const std = @import("std");
const vec = @import("../math/vec.zig");
const core_types = @import("../types.zig");
const types = @import("types.zig");
const llt = @import("../loads/llt.zig");
const V3 = vec.V3;

/// algum par ligado e o voo pelas faixas: a aerodinâmica precisa das circulações antes do laço dos painéis
pub fn active(params: *const core_types.Params) bool {
    if (params.aero_model != 0) return false;
    const n_mods: usize = @intCast(params.n_mod);
    for (params.mods[0..n_mods]) |*modifier| {
        if (modifier.enabled != 0 and modifier.kindOf() == .wing_pair) return true;
    }
    return false;
}

/// verdadeiro se o bit `i` (painel i) está ligado na máscara de 64 bits
inline fn has(mask: [2]i32, i: usize) bool {
    const word: u32 = @bitCast(mask[i / 32]);
    return (word >> @intCast(i % 32)) & 1 != 0;
}

/// −ganho · w_i no painel i (o que entra na velocidade dele); `gamma`: Γ de cada painel; `flow_dir`: para onde o ar vai
pub fn induced(params: *const core_types.Params, modifier: *const types.Modifier, gamma: []const f64, flow_dir: V3, i: usize) V3 {
    const mask_a = modifier.pairMask(true);
    const mask_b = modifier.pairMask(false);
    const src = if (has(mask_a, i)) mask_b else if (has(mask_b, i)) mask_a else return vec.zero;
    const control_point = vec.v3(params.surf[i].r);
    const n_surf: usize = @intCast(params.n_surf);
    var induced_sum = vec.zero;
    for (0..n_surf) |j| {
        if (!has(src, j) or gamma[j] == 0) continue;
        const surface = &params.surf[j];
        const nodes = llt.surfaceNodes(surface);
        induced_sum += llt.horseshoe(control_point, nodes.A, nodes.B, flow_dir, true, llt.core_frac * surface.c) * vec.splat(gamma[j]);
    }
    return -induced_sum * vec.splat(modifier.pair(.gain));
}

const testing = std.testing;

test "máscara do par: bit a bit" {
    try testing.expect(has(.{ 0b110, 0 }, 1));
    try testing.expect(!has(.{ 0b110, 0 }, 0));
    try testing.expect(has(.{ 0, 1 }, 32));
}
