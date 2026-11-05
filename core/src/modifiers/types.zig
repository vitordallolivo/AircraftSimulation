//! Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
//!
//! Duas perguntas separadas:
//!   - qual MÉTODO calcula um efeito que sempre existe (um por vez): um `enum` seletor em `Params`. Aqui, o efeito
//!     solo (`Params.ground`); o modelo do voo (`Params.aero_model`) e a linha sustentadora (`Params.llt_method`)
//!     ficam em `types.zig`. O padrão é o comportamento de antes, então arquivos antigos e o AeroDrive não mudam;
//!   - quais EFEITOS A MAIS estão ligados (somam; esteira da hélice, interferência entre asas, momento do comando):
//!     um item em `Params.mods` com `kind`, `flags` e os ajustes com nome, desligado por padrão (`n_mod = 0`: o
//!     laço nem roda).
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
    /// sem efeito solo
    off = 0,
    /// φ(h/b) de McCormick no arrasto induzido (o de sempre; padrão)
    mccormick = 1,
    /// número de outra versão: tratado como desligado
    _,
};

/// efeitos a mais (`Modifier.kind`)
pub const Kind = enum(i32) {
    /// item vazio (ignorado)
    none = 0,
    /// esteira da hélice por disco atuador (slipstream.zig); ajustes em `SlipstreamSettings`
    slipstream_disk = 1,
    /// interferência entre as asas da configuração, quantas houver (interference.zig); ajustes em
    /// `InterferenceSettings`. Cada painel marcado sente os painéis marcados das outras asas (`Surface.owner`)
    wing_interference = 2,
    /// momento próprio do comando no quarto de corda da faixa (flapmoment.zig); ajustes em `FlapMomentSettings`
    flap_moment = 3,
    /// tipo de outra versão: ignorado
    _,
};

/// o que se liga e desliga num modificador. Na ABI é um `i32`: bit 0 ligado, bit 1 axial, bit 2 giro
pub const Flags = packed struct(u32) {
    /// o modificador vale
    enabled: bool = true,
    /// esteira: a velocidade axial entra
    axial: bool = true,
    /// esteira: o giro entra
    swirl: bool = true,
    _unused: u29 = 0,
};

/// ajustes da esteira (`Kind.slipstream_disk`), nos primeiros `Modifier.params`
pub const SlipstreamSettings = extern struct {
    /// ganho da velocidade axial (1 = a teoria)
    axial_gain: f64 = 1,
    /// ganho do giro (1 = a teoria)
    swirl_gain: f64 = 1,
};

/// ajustes da interferência entre asas (`Kind.wing_interference`)
pub const InterferenceSettings = extern struct {
    /// ganho da velocidade induzida (1 = a teoria)
    gain: f64 = 1,
};

/// ajustes do momento do comando (`Kind.flap_moment`)
pub const FlapMomentSettings = extern struct {
    /// o fator empírico k do τ (o mesmo de `aerosim/model/airfoil.py: flap_effectiveness`)
    factor: f64 = 0.85,
};

pub const n_params = 16;

/// um efeito a mais. Os ajustes ficam nos primeiros `params`, na ordem da struct de ajustes do tipo
/// (`settings`); ver README.md desta pasta.
pub const Modifier = extern struct {
    kind: Kind = .none,
    flags: Flags = .{},
    // superfícies afetadas (painéis do núcleo, bit i = painel i; 0 nos dois = todos)
    surf_mask: [2]i32 = .{ 0, 0 },
    // motores envolvidos (bit i = motor i; 0 = todos)
    prop_mask: i32 = 0,
    _pad: i32 = 0,
    params: [n_params]f64 = [_]f64{0} ** n_params,

    /// os ajustes do modificador lidos como a struct `Settings` do tipo dele
    pub inline fn settings(self: *const Modifier, comptime Settings: type) Settings {
        comptime if (@sizeOf(Settings) > @sizeOf(@TypeOf(self.params))) @compileError("ajustes não cabem em params");
        return std.mem.bytesToValue(Settings, std.mem.asBytes(&self.params)[0..@sizeOf(Settings)]);
    }

    /// o modificador está ligado e é do tipo `kind`?
    pub inline fn isOn(self: *const Modifier, kind: Kind) bool {
        return self.flags.enabled and self.kind == kind;
    }

    /// os painéis que o modificador pega (vazio = todos)
    pub inline fn panels(self: *const Modifier) PanelSet {
        return panelSet(self.surf_mask);
    }

    /// o modificador pega o painel `i`? (sem painéis marcados: pega todos)
    pub inline fn affectsPanel(self: *const Modifier, i: usize) bool {
        const marked = self.panels();
        return marked.mask == 0 or marked.isSet(i);
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
}
