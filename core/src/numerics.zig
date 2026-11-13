//! O refino numérico dos solvers do núcleo num lugar só: quantas iterações, que tolerância, que passo.
//!
//! Antes cada número ficava fixo dentro da função que o usava. Agora quem chama o núcleo (a GUI, pelo arquivo do
//! avião, `Aircraft.numerics`, e pelo "Refino dos Solvers" de cada análise) escreve em `active` antes de rodar, e cada solver lê daqui. O padrão de cada campo é o
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

/// o solver de cada campo do refino: é por ele que a tela junta os campos e decide em que análise cada um aparece
pub const Solver = enum { trim, equilibrium, static, envelope, gust, stall_guard, lifting_line, stall_curve, propulsion, control_moment, sizing, structures };

/// o nome do solver na tela
pub fn solverTitle(solver: Solver) []const u8 {
    return switch (solver) {
        .trim => "trimagem",
        .equilibrium => "equilíbrio e linearização",
        .static => "estabilidade estática",
        .envelope => "envelope de voo",
        .gust => "resposta à rajada",
        .stall_guard => "limite de estol do piloto",
        .lifting_line => "linha sustentadora",
        .stall_curve => "curva de sustentação com estol",
        .propulsion => "hélice e motor",
        .control_moment => "momento do comando",
        .sizing => "dimensionamento",
        .structures => "estruturas e cargas",
    };
}

/// o que a tela mostra de um campo do refino: o solver dele, o rótulo e a dica
pub const Info = struct { field: []const u8, solver: Solver, label: []const u8, help: []const u8 };

/// um por campo de `Numerics`, na ordem dos campos
pub const info = [_]Info{
    .{ .field = "trim_iterations", .solver = .trim, .label = "iterações (Newton)", .help = "iterações do Newton amortecido da trimagem; padrão 120" },
    .{ .field = "trim_step_halvings", .solver = .trim, .label = "cortes do passo", .help = "cortes do passo ao meio em cada iteração da trimagem; padrão 12" },
    .{ .field = "trim_turn_bisections", .solver = .trim, .label = "bisseções nas curvas", .help = "bisseções do fator de carga limite nas curvas; padrão 40" },
    .{ .field = "trim_alpha_min", .solver = .trim, .label = "menor α (rad)", .help = "menor α que a trimagem procura; padrão −0,2 rad" },
    .{ .field = "trim_alpha_max", .solver = .trim, .label = "maior α (rad)", .help = "maior α que a trimagem procura; padrão 0,45 rad" },
    .{ .field = "trim_elevator_limit", .solver = .trim, .label = "profundor máximo (rad)", .help = "maior deflexão do profundor que a trimagem procura, para os dois lados; padrão 0,35 rad" },
    .{ .field = "trim_alpha_step", .solver = .trim, .label = "passo máximo de α (rad)", .help = "o quanto α pode mudar numa iteração; padrão 0,08 rad" },
    .{ .field = "trim_elevator_step", .solver = .trim, .label = "passo máximo do profundor (rad)", .help = "o quanto o profundor pode mudar numa iteração; padrão 0,08 rad" },
    .{ .field = "trim_throttle_step", .solver = .trim, .label = "passo máximo do motor", .help = "o quanto o motor (ou a inclinação, nas curvas) pode mudar numa iteração; padrão 0,25" },
    .{ .field = "equilibrium_iterations", .solver = .equilibrium, .label = "iterações do equilíbrio", .help = "iterações do equilíbrio 6 × 6 antes de linearizar; padrão 60" },
    .{ .field = "equilibrium_step_halvings", .solver = .equilibrium, .label = "cortes do passo", .help = "cortes do passo ao meio em cada iteração do equilíbrio; padrão 10" },
    .{ .field = "linear_step", .solver = .equilibrium, .label = "passo das derivadas", .help = "passo da diferença finita das derivadas dos comandos; padrão 1e-5" },
    .{ .field = "static_trim_iterations", .solver = .static, .label = "iterações de (α, δe)", .help = "iterações do Newton que acha (α, δe) num C_L; padrão 30" },
    .{ .field = "static_trim_step", .solver = .static, .label = "passo das derivadas (rad)", .help = "passo da diferença finita desse Newton (rad); padrão 1e-5" },
    .{ .field = "static_lift_max_bisections", .solver = .static, .label = "bisseções do C_L máx.", .help = "bisseções do C_L máximo trimado; padrão 30" },
    .{ .field = "static_zero_lift_bisections", .solver = .static, .label = "bisseções do C_L zero", .help = "bisseções do α de C_L zero; padrão 50" },
    .{ .field = "static_gear_bisections", .solver = .static, .label = "bisseções do trem", .help = "bisseções da posição limite do trem; padrão 40" },
    .{ .field = "static_alpha_bisections", .solver = .static, .label = "bisseções do α", .help = "bisseções do α de um C_L; padrão 50" },
    .{ .field = "static_bank_time_bisections", .solver = .static, .label = "bisseções da rolagem", .help = "bisseções do tempo até a inclinação pedida; padrão 80" },
    .{ .field = "static_roll_samples", .solver = .static, .label = "pontos do aileron", .help = "pontos da integral da corda do aileron na envergadura; padrão 400" },
    .{ .field = "envelope_speed_bisections", .solver = .envelope, .label = "bisseções de V", .help = "bisseções de cada velocidade limite; padrão 100" },
    .{ .field = "envelope_alpha_bisections", .solver = .envelope, .label = "bisseções do cruzeiro", .help = "bisseções da velocidade do ângulo de cruzeiro; padrão 60" },
    .{ .field = "envelope_alpha_tolerance", .solver = .envelope, .label = "tolerância de V (m/s)", .help = "tolerância dessa velocidade (m/s); padrão 1e-3" },
    .{ .field = "envelope_ceiling_bisections", .solver = .envelope, .label = "bisseções do teto", .help = "bisseções do teto; padrão 60" },
    .{ .field = "envelope_ceiling_tolerance", .solver = .envelope, .label = "tolerância do teto (m)", .help = "tolerância do teto (m); padrão 0.5" },
    .{ .field = "settle_window", .solver = .gust, .label = "janela (s)", .help = "janela olhada (s); padrão 1.0" },
    .{ .field = "settle_alpha", .solver = .gust, .label = "variação de α (°)", .help = "variação máxima de α na janela (graus); padrão 0.05" },
    .{ .field = "settle_rate", .solver = .gust, .label = "maior taxa (°/s)", .help = "maior taxa p, q, r na janela (graus/s); padrão 0.5" },
    .{ .field = "settle_liquid", .solver = .gust, .label = "variação do líquido (°)", .help = "variação máxima de cada pêndulo do líquido (graus); padrão 0.1" },
    .{ .field = "settle_cg", .solver = .gust, .label = "variação do xCG (m)", .help = "variação máxima do xCG (m); padrão 0.05e-3" },
    .{ .field = "guard_alpha_step", .solver = .stall_guard, .label = "passo de α (°)", .help = "passo da varredura de α (graus), de 0 a 30°; padrão 0.25" },
    .{ .field = "llt_newton_iterations", .solver = .lifting_line, .label = "iterações (Newton)", .help = "iterações do Newton da linha sustentadora não linear; padrão 50" },
    .{ .field = "llt_step_halvings", .solver = .lifting_line, .label = "cortes do passo", .help = "cortes do passo ao meio em cada iteração; padrão 11" },
    .{ .field = "llt_pseudo_iterations", .solver = .lifting_line, .label = "iterações pós-estol", .help = "iterações da continuação em pseudo-tempo (depois do estol); padrão 300" },
    .{ .field = "llt_pseudo_step", .solver = .lifting_line, .label = "passo pós-estol", .help = "passo inicial do pseudo-tempo; padrão 0.5" },
    .{ .field = "llt_tolerance", .solver = .lifting_line, .label = "tolerância", .help = "resíduo relativo que conta como convergido; padrão 1e-12" },
    .{ .field = "llt_jacobian_step", .solver = .lifting_line, .label = "passo das derivadas (rad)", .help = "passo de α da diferença finita do jacobiano (rad); padrão 1e-6" },
    .{ .field = "vortex_core_fraction", .solver = .lifting_line, .label = "núcleo do vórtice (corda)", .help = "raio do núcleo do vórtice entre superfícies diferentes, em fração da corda; padrão 0.1" },
    .{ .field = "vortex_leg_length", .solver = .lifting_line, .label = "comprimento das pernas do vórtice (m)", .help = "as pernas que saem para trás fazem o papel de infinito; padrão 1000 m, bem maior que o avião" },
    .{ .field = "section_lift_factor", .solver = .lifting_line, .label = "C_L máx. da faixa / c_l máx. do perfil", .help = "fator com que o c_l máximo do perfil vira o da faixa da asa; padrão 0,9" },
    .{ .field = "peak_golden_iterations", .solver = .stall_curve, .label = "iterações do pico", .help = "iterações da seção áurea do pico de c_l; padrão 40" },
    .{ .field = "stall_angle_bisections", .solver = .stall_curve, .label = "bisseções do α de estol", .help = "bisseções do α de estol que dá o c_l máximo pedido; padrão 50" },
    .{ .field = "section_peak_points", .solver = .stall_curve, .label = "pontos da polar", .help = "pontos da varredura do pico da polar do perfil; padrão 3000" },
    .{ .field = "prop_iterations", .solver = .propulsion, .label = "iterações da rotação", .help = "iterações da rotação de equilíbrio da hélice; padrão 80" },
    .{ .field = "prop_rps_max", .solver = .propulsion, .label = "rotação máxima (rps)", .help = "maior rotação procurada (rps); padrão 600" },
    .{ .field = "motorprop_iterations", .solver = .propulsion, .label = "iterações motor + hélice", .help = "iterações do ponto motor + hélice do dimensionamento; padrão 60" },
    .{ .field = "flap_theta_bisections", .solver = .control_moment, .label = "bisseções do θ", .help = "bisseções do θ do flape; padrão 48" },
    .{ .field = "ground_time_step", .solver = .sizing, .label = "passo da corrida (s)", .help = "passo de tempo da corrida no chão (s); padrão 0.02" },
    .{ .field = "ground_max_steps", .solver = .sizing, .label = "passos da corrida", .help = "máximo de passos da corrida; padrão 20000" },
    .{ .field = "ground_mtow_bisections", .solver = .sizing, .label = "bisseções do MTOW", .help = "bisseções do MTOW da pista; padrão 40" },
    .{ .field = "stage_time_step", .solver = .sizing, .label = "passo da corrida, etapas (s)", .help = "passo de tempo da corrida das etapas (s); padrão 0.01" },
    .{ .field = "stage_max_steps", .solver = .sizing, .label = "passos da corrida, etapas", .help = "máximo de passos dessa corrida; padrão 12000" },
    .{ .field = "stage_ceiling_bisections", .solver = .sizing, .label = "bisseções do teto", .help = "bisseções do teto das etapas; padrão 30" },
    .{ .field = "tail_arm_iterations", .solver = .sizing, .label = "voltas do braço de cauda", .help = "voltas do braço de cauda medido do CG; padrão 30" },
    .{ .field = "tail_span_strips", .solver = .sizing, .label = "faixas da empenagem", .help = "faixas da integração na envergadura da empenagem; padrão 60" },
    .{ .field = "chain_bisections", .solver = .sizing, .label = "bisseções da cadeia", .help = "bisseções da cadeia de dimensionamento; padrão 40" },
    .{ .field = "design_grid_points", .solver = .sizing, .label = "pontos da grade de W/S", .help = "pontos de carga alar em que o ponto de projeto é procurado; padrão 600, até 4096" },
    .{ .field = "liftoff_speed_factor", .solver = .sizing, .label = "V de decolagem / V de estol", .help = "a decolagem do diagrama de restrições acontece a este fator vezes a velocidade de estol; padrão 1,1" },
    .{ .field = "buckling_waves", .solver = .structures, .label = "meias-ondas da flambagem", .help = "meias-ondas testadas em cada direção na flambagem; padrão 12" },
    .{ .field = "flutter_iterations", .solver = .structures, .label = "iterações do flutter", .help = "iterações do p-k do flutter em cada modo; padrão 60" },
};

comptime { // todo campo tem o rótulo dele, na mesma ordem
    @setEvalBranchQuota(20000);
    const fields = @typeInfo(Numerics).@"struct".fields;
    if (fields.len != info.len) @compileError("numerics.info: falta ou sobra um campo");
    for (fields, info) |field, described| if (!std.mem.eql(u8, field.name, described.field)) @compileError("numerics.info fora de ordem em " ++ field.name);
}

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
