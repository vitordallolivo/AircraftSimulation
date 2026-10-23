//! Estruturas trocadas com o Python (C ABI, `extern struct`).
//!
//! Tudo em SI e ângulos em RADIANOS. O Python não precisa copiar estas definições:
//! `abi.zig` gera em comptime um esquema (nome, tipo, offset) que o lado Python lê
//! para montar as estruturas ctypes. Campos marcados "derivado" são calculados em
//! `init` a partir dos demais e podem ser lidos de volta.
const L = @import("limits.zig");
const poly = @import("math/poly.zig");
const MT = @import("modifiers/types.zig");
pub const Modifier = MT.Modifier;

/// polinômio de tração (gerado em comptime a partir do grau em limits.zig)
pub const ThrustPoly = poly.Poly2(L.thrust_poly_deg);

pub const prop_motor = 0; // motor BLDC + hélice por tabela J, C_T, C_P (com dinâmica de rotação)
pub const prop_poly = 1; // tração por polinômio T(x, y) ajustado (sem motor/bateria)

/// variáveis do polinômio de tração
pub const pvar_none = 0;
pub const pvar_V = 1; // velocidade do ar no eixo do motor (m/s)
pub const pvar_throttle = 2; // acelerador 0..1
pub const pvar_h = 3; // altura (m)
pub const pvar_rho = 4; // densidade (kg/m³)
pub const pvar_const = 5; // constante (poly_xc / poly_yc), ex.: a rotação n do conjunto

/// Painel sustentador (faixa de meia asa, EH, EV...). A deflexão vista pelo painel é
///   δ = tau · (mix[0] δe + mix[1] δa + mix[2] δr)
/// o que cobre profundor, aileron, leme, elevon, ruddervator, flaperon etc.
pub const Surface = extern struct {
    r: [3]f64 = .{ 0, 0, 0 }, // centro aerodinâmico no corpo (m)
    S: f64 = 0,
    c: f64 = 0,
    AR: f64 = 5, // alongamento da superfície inteira (arrasto induzido)
    e: f64 = 0.8,
    dihedral: f64 = 0,
    incidence: f64 = 0,
    CLa: f64 = 4.5,
    CL0: f64 = 0,
    CLmax: f64 = 1.2,
    CD0: f64 = 0.01,
    Cmac: f64 = 0,
    tau: f64 = 0,
    mix: [3]f64 = .{ 0, 0, 0 },
    eta: f64 = 1,
    eps0: f64 = 0,
    depsda: f64 = 0,
    group: i32 = 0, // limits.group_*
    vertical: i32 = 0, // normal para +y
    side: i32 = 0, // +1 direita, -1 esquerda, 0 centro
    downwash: i32 = 0, // sente o downwash da asa
    // pontos de 1/4 de corda nas duas bordas da faixa (corpo, m): os nós da ferradura na linha sustentadora das
    // cargas (loads/llt.zig). Zero nos dois: a ferradura sai do centro r ± (S/c)/2 ao longo da envergadura.
    // A simulação (aero.zig) não usa
    qa: [3]f64 = .{ 0, 0, 0 },
    qb: [3]f64 = .{ 0, 0, 0 },
    // derivados
    a0: f64 = 0,
    ex: [3]f64 = .{ 0, 0, 0 },
    ey: [3]f64 = .{ 0, 0, 0 },
    ez: [3]f64 = .{ 0, 0, 0 },
};

/// Motor BLDC + hélice (tabela) + bateria. Cada unidade é independente.
pub const PropUnit = extern struct {
    r: [3]f64 = .{ 0, 0, 0 }, // cubo da hélice (m)
    tilt: f64 = 0, // inclinação do eixo (+ nariz para cima), rad
    toe: f64 = 0, // desvio em guinada, rad
    tilt_range: f64 = 0, // eixo móvel (tilt-rotor): inclinação = tilt + comando·tilt_range, rad; 0 = fixo
    sense: f64 = 1, // +1 horário visto de trás
    D: f64 = 0.3,
    Ip: f64 = 1e-4,
    Jm: f64 = 1e-4,
    Kv: f64 = 1000,
    Rm: f64 = 0.05,
    B: f64 = 0,
    tauc: f64 = 0,
    Imax: f64 = 50,
    Voc: f64 = 11.1,
    Rint: f64 = 0.02,
    yaw_mix: f64 = 0, // acelerador diferencial: thr_i = thr + yaw_mix δr
    model: i32 = prop_motor,
    n_pts: i32 = 0,
    // tração polinomial: T = gain · P(x, y) · (ρ/ρ0)^rho_exp  (× acelerador se nem x nem y for o acelerador)
    poly_x: i32 = pvar_V,
    poly_y: i32 = pvar_none,
    poly_gain: f64 = 1,
    poly_rho_exp: f64 = 0,
    poly_rho0: f64 = 1.225,
    poly_xmax: f64 = 0, // > 0: x limitado a [0, xmax] (faixa do ajuste)
    poly_ymax: f64 = 0,
    poly_xc: f64 = 0, // valor de x quando poly_x = pvar_const
    poly_yc: f64 = 0,
    poly: [ThrustPoly.n_coef]f64 = [_]f64{0} ** ThrustPoly.n_coef,
    J: [L.max_prop_pts]f64 = [_]f64{0} ** L.max_prop_pts,
    CT: [L.max_prop_pts]f64 = [_]f64{0} ** L.max_prop_pts,
    CP: [L.max_prop_pts]f64 = [_]f64{0} ** L.max_prop_pts,
    // derivados
    eT: [3]f64 = .{ 1, 0, 0 },
    D4: f64 = 0,
    D5: f64 = 0,
    Ke: f64 = 0,
};

pub const gear_steer = 0; // direcionável (bequilha do triciclo ou do convencional)
pub const gear_main = 1; // principal (com freio)
pub const gear_skid = 2; // patim/ponto de cauda

pub const Gear = extern struct {
    r: [3]f64 = .{ 0, 0, 0 },
    k: f64 = 3000,
    c: f64 = 80,
    kind: i32 = gear_main,
    _pad: i32 = 0,
};

pub const tank_square = 0;
pub const tank_cylinder = 1;

/// Tanque de base quadrada (lado `side`) ou cilíndrico (diâmetro `side`), líquido com
/// altura `fill`. Pêndulo equivalente do 1º modo (Abramson, NASA SP-106):
///   quadrado:  ω² = (π g / a) tanh(π h / a),     m1 = m 8 tanh(π h/a) / (π³ h/a)
///   cilindro:  ω² = (ξ g / R) tanh(ξ h / R),     m1 = m 2 tanh(ξ h/R) / (ξ (ξ²−1) h/R), ξ = 1,841
///   l = g / ω²,  m0 = m − m1
pub const Tank = extern struct {
    r: [3]f64 = .{ 0, 0, 0 }, // centro do líquido em repouso
    shape: i32 = tank_square,
    _pad: i32 = 0,
    side: f64 = 0.1,
    fill: f64 = 0.05,
    rho: f64 = 1000,
    zeta: f64 = 0.03,
    // derivados
    m_liq: f64 = 0,
    m0: f64 = 0,
    m1: f64 = 0,
    l1: f64 = 0,
    w1: f64 = 0,
};

pub const Segment = extern struct {
    arc: i32 = 0,
    takeoff: i32 = 0,
    landing: i32 = 0,
    _pad: i32 = 0,
    n0: f64 = 0,
    e0: f64 = 0,
    chi0: f64 = 0,
    L: f64 = 0,
    cn: f64 = 0,
    ce: f64 = 0,
    R: f64 = 0,
    lam: f64 = 1,
    h0: f64 = 0,
    h1: f64 = 0,
    V0: f64 = 0,
    V1: f64 = 0,
    clearance: f64 = 0,
};

pub const event_drop = 0;
pub const event_gust = 1;
pub const Event = extern struct { kind: i32 = 0, seg: i32 = 0, s: f64 = 0 };

/// mesa/plataforma: retângulo elevado. Começa em (n0, e0) na linha de centro, vai L metros
/// no rumo chi, largura W centrada, topo a h metros do chão.
pub const Pad = extern struct {
    n0: f64 = 0,
    e0: f64 = 0,
    chi: f64 = 0,
    L: f64 = 0,
    W: f64 = 0,
    h: f64 = 0,
};

pub const Payload = extern struct {
    enabled: i32 = 0,
    _pad: i32 = 0,
    m: f64 = 0,
    r: [3]f64 = .{ 0, 0, 0 },
    bay: f64 = 0.3,
    Fext_g: f64 = 2,
    mu_b: f64 = 0.3,
    CdS_chute: f64 = 0.45,
};

pub const Environment = extern struct {
    rho: f64 = 1.225,
    Vw10: f64 = 0,
    wind_from: f64 = 0, // de onde o vento vem (rad, 0 = norte)
    wind_elev: f64 = 0, // + sobe
    h_ref: f64 = 10,
    gust_T: f64 = 1,
    gust_U: [3]f64 = .{ 0, 0, 0 },
    gust_on: i32 = 0,
    _pad: i32 = 0,
};

pub const Takeoff = extern struct {
    VR: f64 = 12, // puxa o profundor em VR (m/s) ...
    sR: f64 = 0, // ... ou, se sR > 0, na distância sR (m)
    de0: f64 = 0,
    de1: f64 = -0.1,
    rate_de: f64 = 1.0,
    ht: f64 = 2, // altura em que o piloto automático assume
    rate_thr: f64 = 2,
    h_end: f64 = 6, // fim da simulação "só decolagem"
};

/// comandos de quem pilota de fora (controle, simulador): com `manual` = 1 substituem os do piloto
/// automático; com 0 (padrão) nada muda. `drop` = 1 solta a carga LAPES agora.
pub const Pilot = extern struct {
    manual: i32 = 0,
    drop: i32 = 0,
    de: f64 = 0, // rad
    da: f64 = 0,
    dr: f64 = 0,
    thr: f64 = 0, // 0..1
    tilt: f64 = 0, // comando dos eixos móveis, 0..1 (vale também no automático; 0 = posição de `tilt`)
};

pub const Autopilot = extern struct {
    CL0: f64 = 0.45,
    CLa: f64 = 4.5,
    alpha_max: f64 = 0.19,
    g_up: f64 = 0.08,
    g_down: f64 = 0.10,
    Khr: f64 = 0.5,
    Kvs: f64 = 0.5,
    Kn_h: f64 = 0.065,
    Kn_hd: f64 = 0.13,
    Kn_ih: f64 = 0.01,
    Kae: f64 = 4.0,
    KIa: f64 = 4.0,
    Kfn: f64 = 1.2,
    Lorb: f64 = 50,
    tlead: f64 = 0.8,
    Kthe: f64 = 1.5,
    Kqe: f64 = 0.25,
    KV: f64 = 0.25,
    KIV: f64 = 0.08,
    KHT: f64 = 0.10,
    Dtrim: f64 = 0.55,
    Kchi: f64 = 0.8,
    kvf: f64 = 0.05,
    chi_inf: f64 = 1.047,
    korb: f64 = 0.5,
    phimax: f64 = 0.52,
    Kphia: f64 = 2.0,
    Kpa: f64 = 0.10,
    Kbeta: f64 = 1.0,
    tau_phi: f64 = 0.3,
    pmax_cmd: f64 = 1.047,
    Ky: f64 = 0.15,
    Ki: f64 = 0.02,
    Kpsi: f64 = 1.5,
    Kr: f64 = 0.3,
    Kbeq: f64 = 0.5,
    hflare: f64 = 2.5,
    tau_flare: f64 = 1.0,
    kCL: f64 = 0.95,
    de_max: f64 = 0.349,
    da_max: f64 = 0.349,
    dr_max: f64 = 0.436,
};

/// tabela aerodinâmica do avião inteiro (Params.aero_model = 2): C_L, C_D, C_m em α (β = 0, sem taxas nem comandos,
/// momentos em `ref`) mais as derivadas lineares (por rad; taxas por p b/2V, q c/2V, r b/2V). Vem de qualquer método
/// (VLM, AVL, lltdrek...: `aerosim/aero/flight_table.py`). `fus` = 0: o núcleo soma a fuselagem por cima (os métodos
/// de fora não a têm); 1: a tabela já a inclui
pub const AeroTable = extern struct {
    n: i32 = 0,
    fus: i32 = 0,
    alpha: [L.max_tab]f64 = [_]f64{0} ** L.max_tab, // rad, crescente
    CL: [L.max_tab]f64 = [_]f64{0} ** L.max_tab,
    CD: [L.max_tab]f64 = [_]f64{0} ** L.max_tab,
    Cm: [L.max_tab]f64 = [_]f64{0} ** L.max_tab,
    ref: [3]f64 = .{ 0, 0, 0 }, // ponto dos momentos da tabela (corpo, m)
    CYb: f64 = 0,
    Clb: f64 = 0,
    Cnb: f64 = 0,
    CYp: f64 = 0,
    Clp: f64 = 0,
    Cnp: f64 = 0,
    CLq: f64 = 0,
    Cmq: f64 = 0,
    CYr: f64 = 0,
    Clr: f64 = 0,
    Cnr: f64 = 0,
    CLde: f64 = 0,
    Cmde: f64 = 0,
    Clda: f64 = 0,
    Cnda: f64 = 0,
    CYdr: f64 = 0,
    Cldr: f64 = 0,
    Cndr: f64 = 0,
};

/// o que a linha sustentadora (loads/llt.zig) monta uma vez por configuração (`llt.prepare`, chamado em
/// `runner.configure`): para cada ponto de controle i e ferradura j (índice i·max_surfaces + j), de onde saem as pernas
/// livres (jA, jB) e os segmentos que não dependem do escoamento (as juntas s2 = jA→A e s3 = B→jB de Goates e
/// Hunsaker; o ligado A→B). A cada avaliação só as duas pernas livres são calculadas, na mesma ordem de soma: o
/// resultado é o mesmo, bit a bit, que sem o cache. ok = 0 (painéis montados à mão, AeroDrive): a conta inteira
pub const LltCache = extern struct {
    ok: i32 = 0,
    n: i32 = 0,
    gh: i32 = 0, // montado com as correções de Goates e Hunsaker
    used: [L.max_surfaces]i32 = [_]i32{0} ** L.max_surfaces, // o painel tinha geometria na montagem
    jA: [L.max_surfaces * L.max_surfaces][3]f64 = [_][3]f64{.{ 0, 0, 0 }} ** (L.max_surfaces * L.max_surfaces),
    jB: [L.max_surfaces * L.max_surfaces][3]f64 = [_][3]f64{.{ 0, 0, 0 }} ** (L.max_surfaces * L.max_surfaces),
    s2: [L.max_surfaces * L.max_surfaces][3]f64 = [_][3]f64{.{ 0, 0, 0 }} ** (L.max_surfaces * L.max_surfaces),
    s3: [L.max_surfaces * L.max_surfaces][3]f64 = [_][3]f64{.{ 0, 0, 0 }} ** (L.max_surfaces * L.max_surfaces),
    bound: [L.max_surfaces * L.max_surfaces][3]f64 = [_][3]f64{.{ 0, 0, 0 }} ** (L.max_surfaces * L.max_surfaces),
};

pub const Params = extern struct {
    // massa seca: inércia no CG dela, posição desse CG
    m_dry: f64 = 1,
    Ixx: f64 = 0.1,
    Iyy: f64 = 0.1,
    Izz: f64 = 0.1,
    Ixz: f64 = 0,
    r_dry: [3]f64 = .{ 0, 0, 0 },
    // referências aerodinâmicas
    Sref: f64 = 1,
    cref: f64 = 0.3,
    bref: f64 = 2,
    Mst: f64 = 50, // transição linear/placa plana (Beard e McLain)
    // fuselagem
    fus_CDS: f64 = 0,
    fus_Cma: f64 = 0,
    fus_Cnb: f64 = 0,
    fus_CYb: f64 = 0,
    fus_r: [3]f64 = .{ 0, 0, 0 },
    // componentes
    n_surf: i32 = 0,
    n_prop: i32 = 0,
    n_gear: i32 = 0,
    n_tank: i32 = 0,
    n_seg: i32 = 0,
    n_event: i32 = 0,
    slosh_on: i32 = 1,
    _pad0: i32 = 0,
    surf: [L.max_surfaces]Surface = [_]Surface{.{}} ** L.max_surfaces,
    prop: [L.max_props]PropUnit = [_]PropUnit{.{}} ** L.max_props,
    gear: [L.max_gear]Gear = [_]Gear{.{}} ** L.max_gear,
    tank: [L.max_tanks]Tank = [_]Tank{.{}} ** L.max_tanks,
    seg: [L.max_segments]Segment = [_]Segment{.{}} ** L.max_segments,
    event: [L.max_events]Event = [_]Event{.{}} ** L.max_events,
    // atrito no solo
    mu_roll: f64 = 0.04,
    mu_lat: f64 = 0.6,
    mu_brake: f64 = 1.0,
    mu_skid: f64 = 0.35,
    mu_landing: f64 = 0.4,
    payload: Payload = .{},
    env: Environment = .{},
    takeoff: Takeoff = .{},
    ap: Autopilot = .{},
    pilot: Pilot = .{},
    // integração
    dt: f64 = 1e-3,
    tmax: f64 = 400,
    dtlog: f64 = 0.02,
    // paradas (para checkpoint)
    stop_t: f64 = -1, // para em t
    stop_seg: i32 = -1, // para ao entrar no segmento k
    stop_autop: i32 = 0, // para quando o piloto automático liga
    stop_takeoff: i32 = 0, // para em takeoff.h_end acima do chão
    // linha sustentadora das cargas (loads/llt.zig): 0 e 0 = Phillips e Snyder (o de sempre); llt_joint = 0,15 e
    // llt_blend = 1 = Goates e Hunsaker (2021): ferraduras com junta e linha sustentadora efetiva por ponto de controle
    // modelo aerodinâmico do voo (physics/aeromodel.zig): 0 = faixas (o de sempre; o AeroDrive usa este), 1 = linha
    // sustentadora (loads/llt.zig, com llt_joint e llt_blend), 2 = tabela (aero_tab)
    aero_model: i32 = 0,
    aero_tab: AeroTable = .{},
    llt_joint: f64 = 0, // comprimento da junta das pernas, fração da corda no nó (G-H eq. 17)
    llt_blend: f64 = 0, // distância de mistura da linha efetiva, fração da semienvergadura (G-H eq. 7; MachUpX)
    llt_cache: LltCache = .{}, // montado por llt.prepare na configuração (não vem do Python)
    prop_strike: i32 = 0, // 1: a ponta da pá tocar o chão encerra o voo (`crashed`, Events.tprop); 0 (padrão): só registra
    no_payload: i32 = 0, // começa sem a carga
    n_pad: i32 = 0, // mesas/plataformas
    pads: [L.max_pads]Pad = [_]Pad{.{}} ** L.max_pads,
    // modificadores (modifiers/): método do efeito solo e efeitos a mais (desligados por padrão)
    ground: i32 = @intFromEnum(MT.Ground.mccormick),
    n_mod: i32 = 0,
    mods: [L.max_mods]Modifier = [_]Modifier{.{}} ** L.max_mods,
    // derivados
    steer_sign: f64 = 1, // −1 se a roda direcionável está atrás das principais (convencional)
};

/// estado de um painel num instante (saída de `aero.computeTrace`): para ver a carga ao longo da envergadura
pub const PanelState = extern struct {
    r: [3]f64 = .{ 0, 0, 0 }, // centro do painel (corpo, m)
    S: f64 = 0,
    c: f64 = 0,
    group: i32 = -1, // limits.group_*; −1: painel sem escoamento
    side: i32 = 0,
    alpha: f64 = 0, // α local, já com downwash e comando (rad)
    V: f64 = 0, // velocidade local no plano do perfil (m/s)
    CL: f64 = 0,
    CD: f64 = 0,
    L: f64 = 0, // sustentação do painel (N)
    D: f64 = 0, // arrasto do painel (N)
    F: [3]f64 = .{ 0, 0, 0 }, // força aerodinâmica do painel (corpo, N): sustentação + arrasto
    v: [3]f64 = .{ 0, 0, 0 }, // velocidade do painel em relação ao ar, com os modificadores (corpo, m/s)
    vind: [3]f64 = .{ 0, 0, 0 }, // parte dos modificadores (esteira...) em `v` (corpo, m/s)
    ey: [3]f64 = .{ 0, 0, 0 }, // direção da envergadura do painel (corpo)
    ex: [3]f64 = .{ 0, 0, 0 }, // direção da corda, para a frente (corpo; o centro `r` fica a 25 % da corda)
};

/// medidas acumuladas de uma corrida (o "relatório" de eventos)
pub const Events = extern struct {
    tR: f64 = -1,
    tRot: f64 = -1,
    nRot: f64 = 0,
    tLO: f64 = -1,
    nLO: f64 = 0,
    VLO: f64 = 0,
    thLO: f64 = 0,
    tHt: f64 = -1,
    nHt: f64 = 0,
    VHt: f64 = 0,
    gHt: f64 = 0,
    hcmin: f64 = 1e9,
    ratio_to: f64 = 0,
    ratio_mission: f64 = 0,
    qpeak_to: f64 = 0,
    Ipeak: f64 = 0,
    E: f64 = 0,
    E_to: f64 = 0,
    tdrop: f64 = -1,
    ndrop: f64 = 0,
    hdrop: f64 = 0,
    trel: f64 = -1,
    pk_n: f64 = 0,
    pk_e: f64 = 0,
    pk_t: f64 = 0,
    tg: f64 = -1,
    tTD: f64 = -1,
    nTD: f64 = 0,
    nStop: f64 = 0,
    tend: f64 = 0,
    sink: f64 = 0, // quanto o CG desceu abaixo da altura de repouso depois de sair do chão (mesa)
    hgnd_td: f64 = -1, // altura do terreno no ponto do toque (plataforma ou chão)
    hw_min_air: f64 = 1e9, // menor altura das rodas sobre o terreno, no ar, antes do piloto automático
    bounced: f64 = 0,
    completed: f64 = 0,
    stopped: f64 = 0,
    hpmin: f64 = 1e9, // menor folga da ponta da pá sobre o terreno (todos os motores), no voo inteiro (m)
    tprop: f64 = -1, // instante em que a ponta da pá tocou o chão (o voo termina como `crashed`)
};

/// uma linha do registro (ângulos em rad, o Python converte)
pub const LogRow = extern struct {
    t: f64,
    seg: f64,
    n: f64,
    e: f64,
    h: f64,
    phi: f64,
    theta: f64,
    psi: f64,
    p: f64,
    q: f64,
    r: f64,
    Va: f64,
    Vg: f64,
    alpha: f64,
    beta: f64,
    gamma: f64,
    chi: f64,
    s: f64,
    ect: f64,
    hseg: f64,
    href: f64,
    Vref: f64,
    thc: f64,
    alc: f64,
    phic: f64,
    CL: f64,
    CD: f64,
    CDi: f64,
    CY: f64,
    CL_wing: f64,
    CL_ht: f64,
    CY_vt: f64,
    CL_fus: f64,
    ratioCL: f64,
    T: f64,
    Q: f64,
    P: f64,
    Ibat: f64,
    Vbus: f64,
    E: f64, // Wh
    thr: f64,
    de: f64,
    da: f64,
    dr: f64,
    dw: f64,
    N_steer: f64,
    N_main: f64,
    N_skid: f64,
    htail: f64,
    hprop: f64, // folga da ponta da pá mais baixa sobre o terreno (m)
    RN: f64,
    Rnw: f64,
    Rmw: f64,
    hdot: f64,
    nz: f64,
    alim: f64,
    m: f64,
    xcg: f64,
    ycg: f64,
    zcg: f64,
    Ixx: f64,
    Iyy: f64,
    Izz: f64,
    Fslx: f64,
    Fsly: f64,
    sL: f64,
    L_wing: f64,
    L_ht: f64,
    L_vt: f64,
    L_fus: f64,
    L_prop: f64,
    L_gyro: f64,
    L_gear: f64,
    L_liq: f64,
    L_pay: f64,
    L_tot: f64,
    M_wing: f64,
    M_ht: f64,
    M_vt: f64,
    M_fus: f64,
    M_prop: f64,
    M_gyro: f64,
    M_gear: f64,
    M_liq: f64,
    M_pay: f64,
    M_tot: f64,
    N_wing: f64,
    N_ht: f64,
    N_vt: f64,
    N_fus: f64,
    N_prop: f64,
    N_gyro: f64,
    N_gear: f64,
    N_liq: f64,
    N_pay: f64,
    N_tot: f64,
    Wn: f64,
    We: f64,
    Wd: f64,
    pk_n: f64,
    pk_e: f64,
    pk_h: f64,
    hgnd: f64, // altura do terreno (chão, mesa ou plataforma) sob o CG
    hw: f64, // altura das rodas sobre o terreno
    rpm: [L.max_props]f64,
    thrust: [L.max_props]f64,
    current: [L.max_props]f64,
    Ngear: [L.max_gear]f64,
    slosh_x: [L.max_tanks]f64,
    slosh_y: [L.max_tanks]f64,
};

/// coeficientes estáticos (polar)
pub const AeroCoeffs = extern struct {
    CL: f64 = 0,
    CD: f64 = 0,
    CY: f64 = 0,
    Cl: f64 = 0,
    Cm: f64 = 0,
    Cn: f64 = 0,
    CL_wing: f64 = 0,
    CL_ht: f64 = 0,
    ratioCL: f64 = 0,
    CDi: f64 = 0, // parte induzida
    CN: f64 = 0, // força normal (−Z/qS), para transportar momentos
};

/// ponto de operação de uma unidade propulsora em equilíbrio de rotação
pub const PropPoint = extern struct {
    V: f64 = 0,
    rpm: f64 = 0,
    J: f64 = 0,
    T: f64 = 0,
    Q: f64 = 0,
    P_shaft: f64 = 0,
    P_elec: f64 = 0,
    I: f64 = 0,
    eta_prop: f64 = 0,
};

pub const MassProps = extern struct {
    m: f64 = 0,
    cg: [3]f64 = .{ 0, 0, 0 },
    I: [9]f64 = [_]f64{0} ** 9,
    m_liq: f64 = 0,
};

pub const trim_level = 0; // α, δe, acelerador   (γ = 0, n = 1)
pub const trim_climb = 1; // α, δe, γ            (acelerador = 1)
pub const trim_glide = 2; // α, δe, γ            (acelerador = 0)
pub const trim_turn = 3; // α, δe, acelerador   (γ = 0, n dado)

pub const TrimPoint = extern struct {
    ok: i32 = 0,
    _pad: i32 = 0,
    V: f64 = 0,
    alpha: f64 = 0,
    de: f64 = 0,
    thr: f64 = 0,
    gamma: f64 = 0,
    n: f64 = 1,
    ratioCL: f64 = 0,
    CL: f64 = 0,
    D: f64 = 0,
    T: f64 = 0,
    P: f64 = 0,
};

/// uma linha da tabela de desempenho por velocidade
pub const PerfRow = extern struct {
    V: f64 = 0,
    ok_level: f64 = 0,
    alpha_level: f64 = 0,
    de_level: f64 = 0,
    thr_level: f64 = 0,
    ratio_level: f64 = 0,
    CL_level: f64 = 0,
    D_level: f64 = 0,
    T_level: f64 = 0,
    P_level: f64 = 0,
    ok_climb: f64 = 0,
    gamma_max: f64 = 0,
    roc_max: f64 = 0,
    ok_glide: f64 = 0,
    gamma_idle: f64 = 0,
    roc_idle: f64 = 0,
    n_stall: f64 = 0,
    R_stall: f64 = 0,
    phi_stall: f64 = 0,
    n_sust: f64 = 0,
    R_sust: f64 = 0,
    phi_sust: f64 = 0,
};
