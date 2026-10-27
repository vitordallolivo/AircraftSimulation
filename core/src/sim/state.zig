//! Layout do vetor de estados (definido em comptime a partir dos limites)
//! e o estado discreto de uma corrida (o que vai no checkpoint).
const limits = @import("../limits.zig");
const types = @import("../types.zig");

/// o que fica em cada posição do vetor de estados, na ordem
pub const Entry = enum(usize) {
    /// posição norte (m, NED)
    north,
    /// posição leste (m, NED)
    east,
    /// posição para baixo (m, NED; altura = −down)
    down,
    /// rolamento φ (rad)
    roll,
    /// arfagem θ (rad)
    pitch,
    /// guinada ψ (rad)
    yaw,
    /// velocidade u no corpo (m/s)
    vel_x,
    /// velocidade v no corpo (m/s)
    vel_y,
    /// velocidade w no corpo (m/s)
    vel_z,
    /// taxa de rolamento p no corpo (rad/s)
    rate_p,
    /// taxa de arfagem q no corpo (rad/s)
    rate_q,
    /// taxa de guinada r no corpo (rad/s)
    rate_r,
    /// integrador do piloto: erro de altura
    int_height,
    /// integrador do piloto: erro de velocidade
    int_speed,
    /// integrador do piloto: erro de α
    int_alpha,
    /// integrador do piloto: erro de trajetória (desvio lateral)
    int_track,
    /// altura de referência filtrada
    ref_height,
    /// inclinação pedida filtrada
    bank_cmd,
    /// energia tirada das baterias (J)
    energy,
    /// deslizamento da carga
    cargo_slide,
    /// velocidade de deslizamento da carga
    cargo_slide_rate,
    /// rotação do primeiro motor (rps); os outros seguem, max_props posições a partir daqui
    rps0 = 21,
    /// líquido do primeiro tanque: ex, ey, exd, eyd; 4 posições por tanque
    slosh0 = 21 + limits.max_props,
};

/// posição de `entry` no vetor de estados
pub inline fn index(comptime entry: Entry) usize {
    return @intFromEnum(entry);
}

pub const nx = index(.slosh0) + 4 * limits.max_tanks;

pub const Vec = @Vector(nx, f64);

/// índice da rotação (rps) do motor prop_index
pub inline fn rps(prop_index: usize) usize {
    return index(.rps0) + prop_index;
}
/// índice do deslocamento x do líquido do tanque tank_index
pub inline fn sx(tank_index: usize) usize {
    return index(.slosh0) + 4 * tank_index;
}
/// índice do deslocamento y do líquido do tanque tank_index
pub inline fn sy(tank_index: usize) usize {
    return index(.slosh0) + 4 * tank_index + 1;
}
/// índice da velocidade x do líquido do tanque tank_index
pub inline fn sxd(tank_index: usize) usize {
    return index(.slosh0) + 4 * tank_index + 2;
}
/// índice da velocidade y do líquido do tanque tank_index
pub inline fn syd(tank_index: usize) usize {
    return index(.slosh0) + 4 * tank_index + 3;
}

/// modos discretos (mudam só entre passos)
pub const Flags = extern struct {
    seg: i32 = 0,
    brakes: i32 = 0,
    autop: i32 = 0,
    airborne: i32 = 0,
    landed: i32 = 0,
    flare: i32 = 0,
    extracting: i32 = 0,
    released: i32 = 0,
    pk_flying: i32 = 0,
    _pad: i32 = 0,
    ev_done: [limits.max_events]i32 = [_]i32{0} ** limits.max_events,
};

/// tudo o que define o instante (checkpoint). Os parâmetros NÃO vão junto:
/// ao retomar, vêm da configuração nova (é assim que se mudam as etapas seguintes).
pub const Run = extern struct {
    x: [nx]f64 = [_]f64{0} ** nx,
    t: f64 = 0,
    tR: f64 = -1,
    h_ground: f64 = 0,
    tg: f64 = -1,
    h_rest: f64 = 0, // altura do CG sobre o terreno com a aeronave parada no trem
    next_log: f64 = 0,
    pk: [6]f64 = [_]f64{0} ** 6,
    f: Flags = .{},
    ev: types.Events = .{},
    valid: i32 = 0,
    _pad: i32 = 0,
};

/// visão "somente leitura" usada pelos módulos de física
pub const Ctx = struct {
    p: *const types.Params,
    f: *const Flags,
    tR: f64,
    h_ground: f64,
    tg: f64,
    h_rest: f64 = 0,
};
