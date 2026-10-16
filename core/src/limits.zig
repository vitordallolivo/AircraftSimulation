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
pub const max_mods = 8; // modificadores ligados ao mesmo tempo (esteira, tabela...; ver modifiers/)
pub const max_pads = 4; // mesas e plataformas (decolagem/pouso) acima do chão // simulações simultâneas (uma por thread)

/// grupos aerodinâmicos para separar forças e momentos
pub const n_groups = 4;
pub const group_wing = 0;
pub const group_htail = 1;
pub const group_vtail = 2;
pub const group_fuselage = 3;

pub const g0 = 9.80665;
