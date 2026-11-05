//! Tipos do dimensionamento inicial (mini-MDO): a configuração que vem do Python, o vetor de
//! projeto, as grandezas que saem e o registro de um indivíduo do PSO.
//!
//! Tudo `extern struct` (vai no esquema da ABI); as listas têm tamanho fixo e um contador.
const std = @import("std");
const types = @import("../types.zig");

pub const max_airfoils = 64;
pub const max_sets = 64; // conjuntos motor + hélice + bateria
pub const max_cons = 24;
pub const n_curve = 40; // pontos da curva de tração/arrasto

// ------------------------------------------------------------------ variáveis de projeto (índices em x)
/// variável de projeto; o número é a posição dela em `x` e em `SizingCfg.vars`, e o nome é o do Python
pub const Variable = enum(usize) {
    /// envergadura (m)
    span,
    /// área total das asas (m²)
    area,
    /// afilamento (só entra na massa/geometria de desenho)
    taper,
    /// perfil da raiz: índice na lista de perfis
    airfoil,
    /// índice na lista de conjuntos de tração
    set,
    /// número de motores
    motors,
    /// inclinação do motor (graus)
    tilt,
    /// perfil da ponta (a mesma asa com dois perfis; entre eles, interpolado)
    airfoil_tip,
    /// arranjo dos motores: índice na lista de arranjos
    layout,
};
pub const n_vars = @typeInfo(Variable).@"enum".fields.len;
/// os nomes das variáveis na ordem de `x` (os do Python)
pub const var_names: [n_vars][:0]const u8 = blk: {
    var names: [n_vars][:0]const u8 = undefined;
    for (@typeInfo(Variable).@"enum".fields, 0..) |field, i| names[i] = field.name;
    break :blk names;
};

/// a posição da variável `which` em `x`
pub inline fn variable(which: Variable) usize {
    return @intFromEnum(which);
}

/// como a variável anda na busca (`VarSpec.kind`)
pub const VarKind = enum(i32) {
    continuous = 0,
    integer = 1,
    /// índice 0..hi numa lista
    list = 2,
    _,
};

pub const VarSpec = extern struct {
    lo: f64 = 0,
    hi: f64 = 0, // lo = hi: fixa
    kind: VarKind = .continuous,
};

// ------------------------------------------------------------------ grandezas (índices em `Out.q`)
/// grandeza que o dimensionamento calcula; o número é a posição dela em `SizingOut.q`
pub const Quantity = enum(i32) {
    /// área de referência S (m²)
    area = 0,
    /// envergadura b (m)
    span = 1,
    /// alongamento AR
    aspect_ratio = 2,
    /// velocidade de estol V_S (m/s)
    stall_speed = 3,
    /// superfícies sustentadoras e de controle
    surface_count = 4,
    /// potência elétrica máxima dos motores (W)
    motor_power = 5,
    motor_count = 6,
    /// corrida de decolagem (m)
    takeoff_run = 7,
    /// velocidade máxima (m/s)
    max_speed = 8,
    /// razão de subida (m/s)
    climb_rate = 9,
    /// tração / peso
    thrust_to_weight = 10,
    /// massa de projeto = MTOW (kg)
    mass = 11,
    /// peso vazio (kg)
    empty_mass = 12,
    /// carga paga (kg)
    payload = 13,
    /// eficiência estrutural: carga paga / peso vazio
    structural_efficiency = 14,
    /// massa máxima de decolagem (kg)
    mtow = 15,
    /// V de (L/D) máx. (m/s)
    best_glide_speed = 16,
    /// (L/D) máx.
    max_lift_to_drag = 17,
    /// corda da raiz (a maior): a asa cabe num retângulo b × c
    root_chord = 18,
    /// fator de carga sustentado na V da curva (tração e estol)
    turn_load_factor = 19,
    /// gradiente de subida máximo (%)
    climb_gradient = 20,
    /// teto: altitude-densidade em que a subida máxima cai a roc_ceiling (m)
    ceiling = 21,
    /// corrida de pouso (m): toque a 1,15 V_S, frenagem μ_f
    landing_run = 22,
    _,
};
pub const n_q = 23;

/// a posição da grandeza `which` em `SizingOut.q`
pub inline fn quantity(which: Quantity) usize {
    return @intCast(@intFromEnum(which));
}
/// os mesmos nomes do registro do aerosim (`design/registry.QUANTITIES`)
pub const q_names = [n_q][:0]const u8{ "S", "b", "AR", "V_S", "n_surf", "P_motor", "n_motor", "s_to", "V_max", "RC", "TW", "mass", "pv", "cp", "ee", "mtow", "V_LD", "LD", "c_root", "n_turn", "grad", "ceiling", "s_land" };

/// a grandeza depende da massa (entra na busca do MTOW) ou é só da geometria/carga
pub fn massDependent(which: Quantity) bool {
    return switch (which) {
        .stall_speed, .takeoff_run, .max_speed, .climb_rate, .thrust_to_weight, .turn_load_factor, .climb_gradient, .ceiling, .landing_run => true,
        else => false,
    };
}

/// a grandeza que a restrição olha; um número fora da lista vira a mais próxima (como antes do `enum`)
pub fn constrained(constraint: Constraint) Quantity {
    return @enumFromInt(std.math.clamp(@intFromEnum(constraint.q), 0, n_q - 1));
}

/// o sentido da restrição (`Constraint.op`)
pub const Comparison = enum(i32) {
    /// valor ≤ limite
    at_most = 0,
    /// valor ≥ limite
    at_least = 1,
    /// valor = limite, com a tolerância `tol`
    equal = 2,
    _,
};

pub const Constraint = extern struct {
    q: Quantity = .takeoff_run,
    op: Comparison = .at_most,
    value: f64 = 0,
    tol: f64 = 0.02, // "=": tolerância relativa
};

/// quanto a restrição é violada, normalizado pelo valor (0 = cumpre)
pub fn violation(constraint: Constraint, value_now: f64) f64 {
    if (!std.math.isFinite(value_now)) return 1.0;
    const scale = @max(@abs(constraint.value), 1e-6);
    return switch (constraint.op) {
        .at_most => @max(value_now - constraint.value, 0) / scale,
        .at_least => @max(constraint.value - value_now, 0) / scale,
        .equal, _ => @max(@abs(value_now - constraint.value) - constraint.tol * scale, 0) / scale,
    };
}

pub const AirfoilData = extern struct {
    cla: f64 = 6.0, // 1/rad (2D)
    a0_deg: f64 = -2.0,
    clmax: f64 = 1.4,
    cd0: f64 = 0.011,
    cm: f64 = -0.05,
};

pub const max_layouts = 8;

/// arranjo dos motores (tratora no nariz, na asa, propulsora...): o que ele muda nas contas
pub const LayoutData = extern struct {
    thrust_factor: f64 = 1.0, // instalação: tração disponível × fator (propulsora na esteira da asa < 1)
    nacelle_CDS: f64 = 0.0, // C_D·S de cada nacele (m²), somado ao arrasto parasita
    mass_per_motor: f64 = 0.0, // suporte de cada motor (kg), no PV
    n_min: f64 = 1, // quantos motores o arranjo aceita
    n_max: f64 = 1,
    n_step: f64 = 1, // 2: aos pares (simétricos na asa)
};

/// conjunto de tração: a unidade do núcleo (motor + hélice + bateria) e a massa dela
pub const PropSet = extern struct {
    unit: types.PropUnit = .{},
    mass: f64 = 0.8,
    P_max: f64 = 0, // potência elétrica máxima de um motor (W)
};

pub const kind_monoplane = 0;
pub const kind_biplane = 1;
pub const kind_flying_wing = 2;
pub const kind_tailsitter = 3;
pub const kind_vtol = 4;

/// o que a busca otimiza (`SizingCfg.objective`)
pub const Objective = enum(i32) {
    /// a maior massa de decolagem
    mtow = 0,
    /// a maior eficiência estrutural
    structural_efficiency = 1,
    _,
};

pub const SizingCfg = extern struct {
    kind: i32 = kind_monoplane,
    objective: Objective = .mtow,
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
    // curva, teto e pouso
    V_turn: f64 = 0, // V da curva sustentada (m/s); 0: 1,5·V_S (√2·V_S cairia no limite de estol, n = 2 exato)
    roc_ceiling: f64 = 0.5, // subida que define o teto (m/s)
    mu_brake: f64 = 0.3, // atrito na frenagem do pouso
    // variáveis, listas e restrições
    vars: [n_vars]VarSpec = [_]VarSpec{.{}} ** n_vars,
    airfoils: [max_airfoils]AirfoilData = [_]AirfoilData{.{}} ** max_airfoils,
    n_airfoils: i32 = 1,
    tip_same: i32 = 1, // 1: a ponta usa o perfil da raiz (um perfil só na asa)
    sets: [max_sets]PropSet = [_]PropSet{.{}} ** max_sets,
    n_sets: i32 = 1,
    layouts: [max_layouts]LayoutData = [_]LayoutData{.{ .n_max = 8 }} ** max_layouts,
    n_layouts: i32 = 1,
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
    CD0: f64 = 0, // a polar do indivíduo (para o envelope completo e o diagrama de restrições)
    K: f64 = 0,
    CLmax: f64 = 0,
    CLg: f64 = 0, // C_L na corrida
    V: [n_curve]f64 = [_]f64{0} ** n_curve, // curva no MTOW
    T: [n_curve]f64 = [_]f64{0} ** n_curve,
    D: [n_curve]f64 = [_]f64{0} ** n_curve,
};

/// o otimizador da busca (`OptOpts.method`)
pub const SearchMethod = enum(i32) {
    /// enxame de partículas
    particle_swarm = 0,
    /// amostras aleatórias
    random = 1,
    _,
};

/// opções do otimizador (comuns a todos; cada método usa as que fazem sentido para ele)
pub const OptOpts = extern struct {
    method: SearchMethod = .particle_swarm,
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
