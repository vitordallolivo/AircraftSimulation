//! Tipos do dimensionamento inicial (mini-MDO): a configuração que vem do Python, o vetor de
//! projeto, as grandezas que saem e o registro de um indivíduo do PSO.
//!
//! Tudo `extern struct` (vai no esquema da ABI); as listas têm tamanho fixo e um contador.
const std = @import("std");
const T = @import("../types.zig");

pub const max_airfoils = 16;
pub const max_sets = 32; // conjuntos motor + hélice + bateria
pub const max_cons = 24;
pub const n_curve = 40; // pontos da curva de tração/arrasto

// ------------------------------------------------------------------ variáveis de projeto (índices em x)
pub const v_span = 0; // envergadura (m)
pub const v_area = 1; // área total das asas (m²)
pub const v_taper = 2; // afilamento (só entra na massa/geometria de desenho)
pub const v_airfoil = 3; // perfil da raiz: índice na lista de perfis
pub const v_set = 4; // índice na lista de conjuntos de tração
pub const v_motors = 5; // número de motores
pub const v_tilt = 6; // inclinação do motor (graus)
pub const v_airfoil_tip = 7; // perfil da ponta (a mesma asa com dois perfis; entre eles, interpolado)
pub const n_vars = 8;
pub const var_names = [n_vars][:0]const u8{ "span", "area", "taper", "airfoil", "set", "motors", "tilt", "airfoil_tip" };

pub const var_continuous = 0;
pub const var_integer = 1;
pub const var_list = 2; // índice 0..hi numa lista

pub const VarSpec = extern struct {
    lo: f64 = 0,
    hi: f64 = 0, // lo = hi: fixa
    kind: i32 = var_continuous,
};

// ------------------------------------------------------------------ grandezas (índices em `Out.q`)
pub const q_S = 0;
pub const q_b = 1;
pub const q_AR = 2;
pub const q_VS = 3;
pub const q_n_surf = 4;
pub const q_P = 5; // potência elétrica máxima dos motores (W)
pub const q_n_motor = 6;
pub const q_s_to = 7;
pub const q_Vmax = 8;
pub const q_RC = 9;
pub const q_TW = 10;
pub const q_mass = 11; // massa de projeto = MTOW
pub const q_pv = 12;
pub const q_cp = 13;
pub const q_ee = 14;
pub const q_mtow = 15;
pub const q_V_LD = 16; // V de (L/D) máx.
pub const q_LD = 17;
pub const n_q = 18;
/// os mesmos nomes do registro do aerosim (`design/registry.QUANTITIES`)
pub const q_names = [n_q][:0]const u8{ "S", "b", "AR", "V_S", "n_surf", "P_motor", "n_motor", "s_to", "V_max", "RC", "TW", "mass", "pv", "cp", "ee", "mtow", "V_LD", "LD" };

/// a grandeza depende da massa (entra na busca do MTOW) ou é só da geometria/carga
pub fn massDependent(q: usize) bool {
    return switch (q) {
        q_VS, q_s_to, q_Vmax, q_RC, q_TW => true,
        else => false,
    };
}

pub const op_le = 0;
pub const op_ge = 1;
pub const op_eq = 2;

pub const Constraint = extern struct {
    q: i32 = q_s_to,
    op: i32 = op_le,
    value: f64 = 0,
    tol: f64 = 0.02, // "=": tolerância relativa
};

/// quanto a restrição é violada, normalizado pelo valor (0 = cumpre)
pub fn violation(c: Constraint, x: f64) f64 {
    if (!std.math.isFinite(x)) return 1.0;
    const s = @max(@abs(c.value), 1e-6);
    return switch (c.op) {
        op_le => @max(x - c.value, 0) / s,
        op_ge => @max(c.value - x, 0) / s,
        else => @max(@abs(x - c.value) - c.tol * s, 0) / s,
    };
}

pub const AirfoilData = extern struct {
    cla: f64 = 6.0, // 1/rad (2D)
    a0_deg: f64 = -2.0,
    clmax: f64 = 1.4,
    cd0: f64 = 0.011,
    cm: f64 = -0.05,
};

/// conjunto de tração: a unidade do núcleo (motor + hélice + bateria) e a massa dela
pub const PropSet = extern struct {
    unit: T.PropUnit = .{},
    mass: f64 = 0.8,
    P_max: f64 = 0, // potência elétrica máxima de um motor (W)
};

pub const kind_monoplane = 0;
pub const kind_biplane = 1;
pub const kind_flying_wing = 2;
pub const kind_tailsitter = 3;
pub const kind_vtol = 4;

pub const obj_mtow = 0;
pub const obj_ee = 1;

pub const SizingCfg = extern struct {
    kind: i32 = kind_monoplane,
    objective: i32 = obj_mtow,
    rho: f64 = 1.156,
    mu: f64 = 0.04, // atrito de rolamento
    m_max: f64 = 60, // teto da busca do MTOW (kg)
    // aerodinâmica
    oswald: f64 = 0.8,
    clmax_factor: f64 = 0.9, // C_L,max da asa / c_l,max do perfil
    cl_ground: f64 = 0.5, // C_L na corrida / C_L,max
    fuselage_CDS: f64 = 0.012, // C_D·S da fuselagem e do trem (m²)
    tail_area_frac: f64 = 0.25, // área da empenagem / área da asa (asa voadora: 0)
    tail_drag_frac: f64 = 1.0, // arrasto parasita da empenagem relativo ao da asa por área
    gap_ratio: f64 = 0.15, // biplano: vão entre asas / envergadura
    trim_clmax_factor: f64 = 0.8, // asa voadora: perda de C_L,max no equilíbrio sem EH
    // massas
    wing_density: f64 = 1.1, // kg/m²
    tail_density: f64 = 0.7,
    fuselage_mass: f64 = 0.6,
    systems_mass: f64 = 0.35,
    gear_mass: f64 = 0.35,
    vtol_mass_frac: f64 = 0.15, // VTOL: estrutura dos motores de sustentação / massa dos conjuntos
    // pairado (tailsitter, VTOL)
    hover_margin: f64 = 1.3, // tração estática ≥ margem × peso
    // variáveis, listas e restrições
    vars: [n_vars]VarSpec = [_]VarSpec{.{}} ** n_vars,
    airfoils: [max_airfoils]AirfoilData = [_]AirfoilData{.{}} ** max_airfoils,
    n_airfoils: i32 = 1,
    tip_same: i32 = 1, // 1: a ponta usa o perfil da raiz (um perfil só na asa)
    sets: [max_sets]PropSet = [_]PropSet{.{}} ** max_sets,
    n_sets: i32 = 1,
    cons: [max_cons]Constraint = [_]Constraint{.{}} ** max_cons,
    n_cons: i32 = 0,
};

pub const SizingOut = extern struct {
    x: [n_vars]f64 = [_]f64{0} ** n_vars, // o vetor usado (arredondado e dentro dos limites)
    q: [n_q]f64 = [_]f64{0} ** n_q,
    feasible: i32 = 0,
    violation: f64 = 0,
    score: f64 = 0, // o objetivo (MTOW ou EE); o PSO maximiza score − penalidade
    hover: i32 = 0, // decola na vertical
    V: [n_curve]f64 = [_]f64{0} ** n_curve, // curva no MTOW
    T: [n_curve]f64 = [_]f64{0} ** n_curve,
    D: [n_curve]f64 = [_]f64{0} ** n_curve,
};

pub const method_pso = 0;
pub const method_random = 1;

/// opções do otimizador (comuns a todos; cada método usa as que fazem sentido para ele)
pub const OptOpts = extern struct {
    method: i32 = method_pso,
    particles: i32 = 24, // população (PSO: partículas; busca aleatória: amostras por iteração)
    iterations: i32 = 40,
    seed: f64 = 1,
    w: f64 = 0.72, // inércia
    c1: f64 = 1.49, // atração da melhor posição da partícula
    c2: f64 = 1.49, // atração da melhor posição do enxame
    penalty: f64 = 10, // pontuação perdida por unidade de violação (relativa ao objetivo)
};

/// um indivíduo avaliado (o gráfico clicável do otimizador): a GUI refaz os detalhes com `eval`
pub const Individual = extern struct {
    x: [n_vars]f64 = [_]f64{0} ** n_vars,
    iter: i32 = 0,
    particle: i32 = 0,
    feasible: i32 = 0,
    score: f64 = 0,
    fitness: f64 = 0,
    violation: f64 = 0,
    mtow: f64 = 0,
    ee: f64 = 0,
    pv: f64 = 0,
};
