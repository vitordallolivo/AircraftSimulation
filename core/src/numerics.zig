//! O refino numérico dos solvers do núcleo num lugar só: quantas iterações, que tolerância, que passo.
//!
//! Antes cada número ficava fixo dentro da função que o usava. Agora quem chama o núcleo (a GUI, pelo arquivo do
//! avião: `Aircraft.numerics`) escreve em `active` antes de rodar, e cada solver lê daqui. O padrão de cada campo é o
//! valor de sempre, então um avião sem a chave no arquivo, o AeroDrive e a regressão dão o mesmo resultado, bit a bit.
//!
//! `active` vale para o programa todo (como a memória estática do núcleo): trocar no meio de uma conta de outra
//! thread muda o refino dela a partir dali, sem estragar memória.
const std = @import("std");

/// o refino de cada solver; os campos são `i32` (contagens) e `f64`, com os mesmos nomes no arquivo do avião
pub const Numerics = extern struct {
    // trimagem (sim/trim.zig)
    /// iterações do Newton amortecido da trimagem
    trim_iterations: i32 = 120,
    /// cortes do passo ao meio em cada iteração da trimagem
    trim_step_halvings: i32 = 12,
    /// bisseções do fator de carga limite nas curvas
    trim_turn_bisections: i32 = 40,
    /// menor α que a trimagem procura (rad)
    trim_alpha_min: f64 = -0.2,
    /// maior α que a trimagem procura (rad)
    trim_alpha_max: f64 = 0.45,
    /// maior deflexão do profundor que a trimagem procura, para os dois lados (rad)
    trim_elevator_limit: f64 = 0.35,
    /// maior passo de α numa iteração (rad)
    trim_alpha_step: f64 = 0.08,
    /// maior passo do profundor numa iteração (rad)
    trim_elevator_step: f64 = 0.08,
    /// maior passo do motor (ou da inclinação) numa iteração
    trim_throttle_step: f64 = 0.25,

    // equilíbrio e linearização (sim/linear.zig)
    /// iterações do equilíbrio 6 × 6 antes de linearizar
    equilibrium_iterations: i32 = 60,
    /// cortes do passo ao meio em cada iteração do equilíbrio
    equilibrium_step_halvings: i32 = 10,
    /// passo da diferença finita das derivadas dos comandos
    linear_step: f64 = 1e-5,

    // estabilidade estática (sim/static.zig)
    /// iterações do Newton que acha (α, δe) num C_L
    static_trim_iterations: i32 = 30,
    /// passo da diferença finita desse Newton (rad)
    static_trim_step: f64 = 1e-5,
    /// bisseções do C_L máximo trimado
    static_lift_max_bisections: i32 = 30,
    /// bisseções do α de C_L zero
    static_zero_lift_bisections: i32 = 50,
    /// bisseções da posição limite do trem
    static_gear_bisections: i32 = 40,
    /// bisseções do α de um C_L
    static_alpha_bisections: i32 = 50,
    /// bisseções do tempo até a inclinação pedida
    static_bank_time_bisections: i32 = 80,
    /// pontos da integral da corda do aileron na envergadura
    static_roll_samples: i32 = 400,

    // envelope de voo (sim/envelope.zig)
    /// bisseções de cada velocidade limite
    envelope_speed_bisections: i32 = 100,
    /// bisseções da velocidade do ângulo de cruzeiro
    envelope_alpha_bisections: i32 = 60,
    /// tolerância dessa velocidade (m/s)
    envelope_alpha_tolerance: f64 = 1e-3,
    /// bisseções do teto
    envelope_ceiling_bisections: i32 = 60,
    /// tolerância do teto (m)
    envelope_ceiling_tolerance: f64 = 0.5,

    // resposta à rajada (sim/gust.zig): quando a resposta conta como estabilizada
    /// janela olhada (s)
    settle_window: f64 = 1.0,
    /// variação máxima de α na janela (graus)
    settle_alpha: f64 = 0.05,
    /// maior taxa p, q, r na janela (graus/s)
    settle_rate: f64 = 0.5,
    /// variação máxima de cada pêndulo do líquido (graus)
    settle_liquid: f64 = 0.1,
    /// variação máxima do xCG (m)
    settle_cg: f64 = 0.05e-3,

    // limite de estol do piloto (sim/runner.zig)
    /// passo da varredura de α (graus), de 0 a 30°
    guard_alpha_step: f64 = 0.25,

    // linha sustentadora (loads/llt.zig)
    /// iterações do Newton da linha sustentadora não linear
    llt_newton_iterations: i32 = 50,
    /// cortes do passo ao meio em cada iteração
    llt_step_halvings: i32 = 11,
    /// iterações da continuação em pseudo-tempo (depois do estol)
    llt_pseudo_iterations: i32 = 300,
    /// passo inicial do pseudo-tempo
    llt_pseudo_step: f64 = 0.5,
    /// resíduo relativo que conta como convergido
    llt_tolerance: f64 = 1e-12,
    /// passo de α da diferença finita do jacobiano (rad)
    llt_jacobian_step: f64 = 1e-6,
    /// raio do núcleo do vórtice entre superfícies diferentes, em fração da corda
    vortex_core_fraction: f64 = 0.1,
    /// comprimento das pernas do vórtice que fazem o papel de infinito (m)
    vortex_leg_length: f64 = 1e3,
    /// C_L máximo da faixa dividido pelo c_l máximo do perfil
    section_lift_factor: f64 = 0.9,

    // curva de sustentação com estol (loads/llt.zig, physics/aero.zig, physics/section.zig)
    /// iterações da seção áurea do pico de c_l
    peak_golden_iterations: i32 = 40,
    /// bisseções do α de estol que dá o c_l máximo pedido
    stall_angle_bisections: i32 = 50,
    /// pontos da varredura do pico da polar do perfil
    section_peak_points: i32 = 3000,

    // hélice e motor (physics/propulsion.zig, sizing/motorprop.zig)
    /// iterações da rotação de equilíbrio da hélice
    prop_iterations: i32 = 80,
    /// maior rotação procurada (rps)
    prop_rps_max: f64 = 600,
    /// iterações do ponto motor + hélice do dimensionamento
    motorprop_iterations: i32 = 60,

    // momento do comando (modifiers/flapmoment.zig)
    /// bisseções do θ do flape
    flap_theta_bisections: i32 = 48,

    // dimensionamento (sizing/)
    /// passo de tempo da corrida no chão (s)
    ground_time_step: f64 = 0.02,
    /// máximo de passos da corrida
    ground_max_steps: i32 = 20000,
    /// bisseções do MTOW da pista
    ground_mtow_bisections: i32 = 40,
    /// passo de tempo da corrida das etapas (s)
    stage_time_step: f64 = 0.01,
    /// máximo de passos dessa corrida
    stage_max_steps: i32 = 12000,
    /// bisseções do teto das etapas
    stage_ceiling_bisections: i32 = 30,
    /// voltas do braço de cauda medido do CG
    tail_arm_iterations: i32 = 30,
    /// faixas da integração na envergadura da empenagem
    tail_span_strips: i32 = 60,
    /// bisseções da cadeia de dimensionamento
    chain_bisections: i32 = 40,
    /// pontos da grade de carga alar em que o ponto de projeto é procurado (até 4096)
    design_grid_points: i32 = 600,
    /// velocidade de decolagem dividida pela de estol
    liftoff_speed_factor: f64 = 1.1,

    // estruturas e cargas
    /// meias-ondas testadas em cada direção na flambagem
    buckling_waves: i32 = 12,
    /// iterações do p-k do flutter em cada modo
    flutter_iterations: i32 = 60,
};

/// o refino em uso
pub var active: Numerics = .{};

/// uma contagem do refino como `usize` (no mínimo 1)
pub inline fn count(value: i32) usize {
    return @intCast(@max(value, 1));
}

test "o padrão é o de sempre" {
    const defaults: Numerics = .{};
    try std.testing.expectEqual(@as(usize, 120), count(defaults.trim_iterations));
    try std.testing.expectEqual(@as(usize, 1), count(0));
}
