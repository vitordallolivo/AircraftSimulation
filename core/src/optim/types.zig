//! Tipos do aeroopt no núcleo: o programa de pilha que calcula a nota de um candidato. O Python traduz o
//! arquivo de pontuação (`aeroopt/scoring.py`) para isto; os códigos das operações são os mesmos de lá.
//!
//! Tudo `extern struct` (vai no esquema da ABI); as listas têm tamanho fixo e um contador.
pub const max_ops = 256;
pub const max_consts = 64;
pub const max_slots = 64;
pub const max_tiers = 8;
pub const max_steps = 8; // degraus de uma faixa
pub const max_stack = 16;

pub const Op = enum(i32) {
    @"const" = 0, // empilha consts[arg]
    load = 1, // empilha vagas[arg]
    store = 2, // desempilha para vagas[arg]
    add = 3,
    sub = 4,
    mul = 5,
    div = 6,
    pow = 7,
    neg = 8,
    min = 9,
    max = 10,
    exp = 11,
    abs = 12,
    tier = 13, // troca o topo pelo valor da faixa tiers[arg]
};

/// degraus: o primeiro limite com x ≤ limite dá o valor; acima de todos (ou NaN), `outside`
pub const Tier = extern struct {
    limits: [max_steps]f64 = @splat(0),
    values: [max_steps]f64 = @splat(0),
    n: i32 = 0,
    outside: f64 = 0,
};

pub const Program = extern struct {
    ops: [max_ops]i32 = @splat(0),
    args: [max_ops]i32 = @splat(0),
    n_ops: i32 = 0,
    consts: [max_consts]f64 = @splat(0),
    n_consts: i32 = 0,
    tiers: [max_tiers]Tier = @splat(.{}),
    n_tiers: i32 = 0,
    n_inputs: i32 = 0, // as entradas ocupam as primeiras vagas
    n_slots: i32 = 0,
};
