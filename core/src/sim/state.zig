//! Layout do vetor de estados (definido em comptime a partir dos limites)
//! e o estado discreto de uma corrida (o que vai no checkpoint).
const limits = @import("../limits.zig");
const types = @import("../types.zig");

pub const N = 0;
pub const E = 1;
pub const D = 2;
pub const PHI = 3;
pub const THE = 4;
pub const PSI = 5;
pub const U = 6;
pub const V = 7;
pub const W = 8;
pub const P = 9;
pub const Q = 10;
pub const R = 11;
pub const IH = 12; // integradores do piloto
pub const IV = 13;
pub const ITH = 14;
pub const IE = 15;
pub const HR = 16; // altura de referência filtrada
pub const PHC = 17; // inclinação pedida filtrada
pub const EN = 18; // energia tirada das baterias (J)
pub const SL = 19; // deslizamento da carga
pub const SLD = 20;
pub const RPS0 = 21; // rotação de cada motor (rps)
pub const SLOSH0 = RPS0 + limits.max_props; // por tanque: ex, ey, exd, eyd
pub const nx = SLOSH0 + 4 * limits.max_tanks;

pub const Vec = @Vector(nx, f64);

pub inline fn rps(i: usize) usize {
    return RPS0 + i;
}
pub inline fn sx(i: usize) usize {
    return SLOSH0 + 4 * i;
}
pub inline fn sy(i: usize) usize {
    return SLOSH0 + 4 * i + 1;
}
pub inline fn sxd(i: usize) usize {
    return SLOSH0 + 4 * i + 2;
}
pub inline fn syd(i: usize) usize {
    return SLOSH0 + 4 * i + 3;
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
