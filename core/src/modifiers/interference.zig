//! Interferência entre as asas da configuração no modelo de faixas, para quantas asas houver.
//!
//! As faixas tratam cada painel sozinho: a asa de trás não sente o downwash da da frente, e asas uma sobre a outra
//! não se induzem. A linha sustentadora (loads/llt.zig) resolve isso montando e resolvendo o sistema das circulações
//! de todos os painéis; aqui entra só a parte entre asas diferentes, numa passada, sem sistema:
//!
//!   1. cada painel j das asas marcadas tem a circulação da sua própria carga de faixa (Kutta–Joukowski,
//!      ρ V Γ = ½ ρ V² c η c_l, o mesmo k_i de llt.zig):  Γ_j = ½ V_j c_j η_j C_L,j
//!      com o α do painel sem esta interferência (com os outros modificadores, o downwash empírico e os comandos);
//!   2. no ponto de controle i, a velocidade induzida pelas ferraduras dos painéis das OUTRAS asas:
//!      w_i = Σ_j Γ_j w_ij,   w_ij = ferradura de Γ = 1 de j (segmento ligado + pernas ao longo do escoamento),
//!      Biot–Savart de segmento reto (Katz e Plotkin, "Low-Speed Aerodynamics", 2ª ed., cap. 10, como em llt.zig;
//!      números das equações a conferir no PDF), com o núcleo de Scully entre superfícies (llt.core_frac);
//!   3. o painel i vê v = V_ar + ω × r − ganho · w_i: outro α e a força girada (o arrasto induzido da interferência
//!      sai da inclinação da sustentação, como na linha sustentadora).
//!
//! "Outra asa" é outro dono (`Surface.owner`, o índice da superfície de onde o painel veio); painel sem dono
//! (`owner` < 0) fica de fora. A própria asa fica de fora (a faixa já tem o seu C_Di = C_L²/(π e AR)). Por ser uma
//! passada, uma asa não devolve o efeito para a outra pelo α dela (é a primeira iteração do sistema). Com outro
//! modelo do voo que não as faixas não faz nada: na linha sustentadora a interferência já está no sistema.
const std = @import("std");
const numerics = @import("../numerics.zig");
const vec = @import("../math/vec.zig");
const core_types = @import("../types.zig");
const types = @import("types.zig");
const llt = @import("../loads/llt.zig");
const V3 = vec.V3;

/// alguma interferência ligada e o voo pelas faixas: a aerodinâmica precisa das circulações antes do laço dos painéis
pub fn active(params: *const core_types.Params) bool {
    if (params.aero_model != .strips) return false;
    const n_mods: usize = @intCast(params.n_mod);
    for (params.mods[0..n_mods]) |*modifier| {
        if (modifier.isOn(.wing_interference)) return true;
    }
    return false;
}

/// −ganho · w_i no painel i (o que entra na velocidade dele); `gamma`: Γ de cada painel; `flow_dir`: para onde o ar vai
pub fn induced(params: *const core_types.Params, modifier: *const types.Modifier, gamma: []const f64, flow_dir: V3, i: usize) V3 {
    const owner = params.surf[i].owner;
    if (owner < 0) return vec.zero;
    const control_point = vec.v3(params.surf[i].r);
    const n_surf: usize = @intCast(params.n_surf);
    var induced_sum = vec.zero;
    for (0..n_surf) |j| {
        const surface = &params.surf[j];
        if (surface.owner < 0 or surface.owner == owner or !modifier.affectsPanel(j) or gamma[j] == 0) continue;
        const nodes = llt.surfaceNodes(surface);
        induced_sum += llt.horseshoe(control_point, nodes.A, nodes.B, flow_dir, true, numerics.active.vortex_core_fraction * surface.c) * vec.splat(gamma[j]);
    }
    return -induced_sum * vec.splat(modifier.settings(types.InterferenceSettings).gain);
}
