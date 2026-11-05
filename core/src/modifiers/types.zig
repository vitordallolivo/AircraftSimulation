//! Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
//!
//! Dois jeitos de um modificador entrar:
//!   - método de um efeito que sempre existe (efeito solo): um campo seletor em `Params` (`ground`);
//!     o padrão é o comportamento de antes, então arquivos antigos e o AeroDrive não mudam;
//!   - efeito a mais (esteira da hélice, tabela de correção...): um item em `Params.mods`, desligado
//!     por padrão (`n_mod = 0`: o laço nem roda).
const std = @import("std");
const limits = @import("../limits.zig");

/// conjunto de painéis do núcleo (bit i = painel i), até 64
pub const PanelSet = std.bit_set.IntegerBitSet(64);
/// conjunto de motores (bit j = motor j), até 32
pub const PropSet = std.bit_set.IntegerBitSet(32);

/// o conjunto de painéis que a ABI guarda em dois `i32` (bits 0..31 e 32..63)
pub fn panelSet(words: [2]i32) PanelSet {
    const low: u32 = @bitCast(words[0]);
    const high: u32 = @bitCast(words[1]);
    return .{ .mask = @as(u64, high) << 32 | low };
}

// Na ABI os seletores são `i32` (o Python escreve o número); dentro do núcleo viram estes enums, e o `switch`
// sobre eles diz por nome o que cada número liga. Número novo = um campo novo no enum, no fim.

/// efeito solo: um método por vez (`Params.ground`)
pub const Ground = enum(i32) {
    off = 0, // sem efeito solo
    mccormick = 1, // φ(h/b) de McCormick no arrasto induzido (o de sempre; padrão)
    _, // número de outra versão: tratado como desligado
};

/// efeitos a mais (`Modifier.kind`)
pub const Kind = enum(i32) {
    none = 0, // item vazio (ignorado)
    slipstream_disk = 1, // esteira da hélice por disco atuador (slipstream.zig); parâmetros em `SlipstreamParam`
    wing_pair = 2, // interferência entre duas asas ligadas (tandem, biplano; wingpair.zig); parâmetros em `PairParam`
    flap_moment = 3, // momento próprio do comando no quarto de corda da faixa (flapmoment.zig); params[0] = k
    _, // tipo de outra versão: ignorado
};

/// o que cada `Modifier.params[k]` quer dizer em `Kind.slipstream_disk` (o valor é o índice k)
pub const SlipstreamParam = enum(u8) {
    axial_on = 0, // velocidade axial ligada (1/0)
    swirl_on = 1, // giro ligado (1/0)
    axial_gain = 2, // ganho da axial (1 = a teoria)
    swirl_gain = 3, // ganho do giro (1 = a teoria)
};

/// o que cada `Modifier.params[k]` quer dizer em `Kind.wing_pair`. As máscaras são as dos painéis de cada asa do
/// par (bits de um i32 com sinal, guardados num f64: exatos), na mesma convenção de `surf_mask`
pub const PairParam = enum(u8) {
    gain = 0, // ganho da velocidade induzida (1 = a teoria)
    a_lo = 1, // painéis da asa A, bits 0..31
    a_hi = 2, // painéis da asa A, bits 32..63
    b_lo = 3, // painéis da asa B, bits 0..31
    b_hi = 4, // painéis da asa B, bits 32..63
};

pub const n_params = 16;

/// um efeito a mais. O que cada parâmetro quer dizer depende de `kind` (ver README.md desta pasta).
pub const Modifier = extern struct {
    kind: i32 = @intFromEnum(Kind.none),
    enabled: i32 = 1,
    // superfícies afetadas (painéis do núcleo, bit i = painel i; 0 nos dois = todos)
    surf_mask: [2]i32 = .{ 0, 0 },
    // motores envolvidos (bit i = motor i; 0 = todos)
    prop_mask: i32 = 0,
    _pad: i32 = 0,
    params: [n_params]f64 = [_]f64{0} ** n_params,

    /// o tipo pelo nome (número desconhecido vira um valor sem nome, que o `switch` ignora)
    pub inline fn kindOf(self: *const Modifier) Kind {
        return @enumFromInt(self.kind);
    }

    /// o parâmetro `param` de um modificador do tipo `Kind.slipstream_disk`
    pub inline fn slip(self: *const Modifier, param: SlipstreamParam) f64 {
        return self.params[@intFromEnum(param)];
    }

    /// o parâmetro `param` de um modificador do tipo `Kind.wing_pair`
    pub inline fn pair(self: *const Modifier, param: PairParam) f64 {
        return self.params[@intFromEnum(param)];
    }

    /// os painéis da asa A (`wing_a` = true) ou B do par
    pub inline fn pairPanels(self: *const Modifier, wing_a: bool) PanelSet {
        const lo = self.pair(if (wing_a) .a_lo else .b_lo);
        const hi = self.pair(if (wing_a) .a_hi else .b_hi);
        return panelSet(.{ @intFromFloat(lo), @intFromFloat(hi) });
    }

    /// o modificador pega o painel `i`? (sem painéis marcados: pega todos)
    pub inline fn affectsPanel(self: *const Modifier, i: usize) bool {
        const panels = panelSet(self.surf_mask);
        return panels.mask == 0 or panels.isSet(i);
    }

    /// o modificador usa o motor `j`? (sem motores marcados: usa todos)
    pub inline fn affectsProp(self: *const Modifier, j: usize) bool {
        const props: PropSet = .{ .mask = @bitCast(self.prop_mask) };
        return props.mask == 0 or props.isSet(j);
    }
};

comptime {
    if (limits.max_surfaces > 64) @compileError("surf_mask cobre até 64 painéis");
    if (limits.max_props > 31) @compileError("prop_mask cobre até 31 motores");
    for (@typeInfo(SlipstreamParam).@"enum".fields) |field| if (field.value >= n_params) @compileError("parâmetro fora de params");
    for (@typeInfo(PairParam).@"enum".fields) |field| if (field.value >= n_params) @compileError("parâmetro fora de params");
}
