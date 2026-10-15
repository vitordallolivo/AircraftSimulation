//! Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
//!
//! Dois jeitos de um modificador entrar:
//!   - método de um efeito que sempre existe (efeito solo): um campo seletor em `Params` (`ground`);
//!     o padrão é o comportamento de antes, então arquivos antigos e o AeroDrive não mudam;
//!   - efeito a mais (esteira da hélice, tabela de correção...): um item em `Params.mods`, desligado
//!     por padrão (`n_mod = 0`: o laço nem roda).
const L = @import("../limits.zig");

// ---- efeito solo: um método por vez (`Params.ground`)
pub const ground_off = 0; // sem efeito solo
pub const ground_mccormick = 1; // φ(h/b) de McCormick no arrasto induzido (o de sempre; padrão)

// ---- efeitos a mais (`Modifier.kind`)
pub const kind_none = 0; // item vazio (ignorado)

pub const n_params = 16;

/// um efeito a mais. O que cada parâmetro quer dizer depende de `kind` (ver README.md desta pasta).
pub const Modifier = extern struct {
    kind: i32 = kind_none,
    enabled: i32 = 1,
    // superfícies afetadas (painéis do núcleo, bit i = painel i; 0 nos dois = todos)
    surf_mask: [2]i32 = .{ 0, 0 },
    // motores envolvidos (bit i = motor i; 0 = todos)
    prop_mask: i32 = 0,
    _pad: i32 = 0,
    params: [n_params]f64 = [_]f64{0} ** n_params,
};

comptime {
    if (L.max_surfaces > 64) @compileError("surf_mask cobre até 64 painéis");
    if (L.max_props > 31) @compileError("prop_mask cobre até 31 motores");
}
