//! Limites de compilação. Toda a memória do núcleo é estática e dimensionada aqui:
//! nada é alocado em tempo de execução. Aumentar um limite só aumenta os vetores fixos.

pub const max_surfaces = 48; // painéis sustentadores (meias asas em faixas, EH, EV, ...)
pub const max_props = 8; // unidades propulsoras (motor + hélice + bateria)
pub const max_prop_pts = 64; // pontos da tabela J, C_T, C_P de cada hélice
pub const thrust_poly_deg = 5; // grau do polinômio de tração T(x, y) (poly55: 21 coeficientes)
pub const max_gear = 8; // pontos de contato com o solo
pub const max_tanks = 8; // tanques com sloshing
pub const max_segments = 32; // pernas do percurso
pub const max_events = 16; // eventos (soltura de carga, rajada)
pub const max_instances = 16;
pub const max_tab = 64; // pontos em α da tabela aerodinâmica (Params.aero_tab; aero_model = 2)
pub const max_mods = 8; // modificadores ligados ao mesmo tempo (esteira, tabela...; ver modifiers/)
pub const max_pads = 4; // mesas e plataformas (decolagem/pouso) acima do chão // simulações simultâneas (uma por thread)

/// grupo aerodinâmico de um painel, para separar forças e momentos (`Surface.group`, `PanelState.group`)
pub const Group = enum(i32) {
    /// painel sem escoamento (só em `PanelState`)
    none = -1,
    wing = 0,
    htail = 1,
    vtail = 2,
    fuselage = 3,
    _,
};
pub const n_groups = 4;

/// a posição do grupo `group` nos vetores por grupo (`aero.Out.Fg`, `Mg`)
pub inline fn groupIndex(group: Group) usize {
    return @intCast(@intFromEnum(group));
}

pub const g0 = 9.80665;
