//! Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
//!
//! Dois jeitos de um modificador entrar:
//!   - método de um efeito que sempre existe (efeito solo): um campo seletor em `Params` (`ground`);
//!     o padrão é o comportamento de antes, então arquivos antigos e o AeroDrive não mudam;
//!   - efeito a mais (esteira da hélice, tabela de correção...): um item em `Params.mods`, desligado
//!     por padrão (`n_mod = 0`: o laço nem roda).
const L = @import("../limits.zig");

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
    pub inline fn kindOf(m: *const Modifier) Kind {
        return @enumFromInt(m.kind);
    }

    /// o parâmetro `k` de um modificador do tipo `Kind.slipstream_disk`
    pub inline fn slip(m: *const Modifier, k: SlipstreamParam) f64 {
        return m.params[@intFromEnum(k)];
    }

    /// o parâmetro `k` de um modificador do tipo `Kind.wing_pair`
    pub inline fn pair(m: *const Modifier, k: PairParam) f64 {
        return m.params[@intFromEnum(k)];
    }

    /// a máscara de painéis da asa A (`a` = true) ou B do par
    pub inline fn pairMask(m: *const Modifier, a: bool) [2]i32 {
        const lo = m.pair(if (a) .a_lo else .b_lo);
        const hi = m.pair(if (a) .a_hi else .b_hi);
        return .{ @intFromFloat(lo), @intFromFloat(hi) };
    }
};

comptime {
    if (L.max_surfaces > 64) @compileError("surf_mask cobre até 64 painéis");
    if (L.max_props > 31) @compileError("prop_mask cobre até 31 motores");
    for (@typeInfo(SlipstreamParam).@"enum".fields) |f| if (f.value >= n_params) @compileError("parâmetro fora de params");
    for (@typeInfo(PairParam).@"enum".fields) |f| if (f.value >= n_params) @compileError("parâmetro fora de params");
}
