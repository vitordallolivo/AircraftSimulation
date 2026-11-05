//! Tipos de aeronave do dimensionamento: cada um é um tipo Zig com a mesma interface, conferida em
//! comptime (`check`). A cadeia (`chain.Chain(Kind, Thrust)`) é gerada para cada tipo, sem `if` de
//! configuração no meio das contas.
//!
//! Interface de um tipo:
//!   name: [:0]const u8
//!   fn wings(cfg) u32                            asas que dividem a área (`SizingCfg.wing_count` no convencional)
//!   tail: bool                                   tem empenagem (massa e arrasto pela fração da asa)
//!   hover: Hover                                 .none | .optional (decola na vertical se der) | .required
//!   fn inducedFactor(cfg) f64                    multiplica K = 1/(π AR e) (N asas: `wingsInducedFactor`, Prandtl)
//!   fn clmaxFactor(cfg) f64                      C_L,max da aeronave / c_l,max do perfil
//!   fn extraMass(cfg, sets_mass) f64             massa própria do tipo (VTOL: estrutura dos motores de sustentação)
//!   fn surfaces(cfg) u32                            superfícies sustentadoras e de controle (para a restrição)
//!
//! Novo tipo: escreva o struct e ponha em `all`; a ABI e o Python passam a aceitá-lo pelo índice.
const std = @import("std");
const sizing_types = @import("types.zig");

pub const Hover = enum { none, optional, required };

/// σ de interferência entre duas asas de mesma envergadura com vão G entre elas, pelo vão/envergadura G/b (Prandtl,
/// NACA TN 182, a fórmula aproximada σ ≈ (1 − 0,66 G/b)/(1,055 + 3,7 G/b), válida de G/b = 1/15 a 1/2; o 1,055 a
/// conferir no PDF, que o OCR lê 1,05)
pub fn pairSigma(gap_ratio: f64) f64 {
    const gap = std.math.clamp(gap_ratio, 0.0, 1.0);
    return std.math.clamp((1.0 - 0.66 * gap) / (1.055 + 3.7 * gap), 0.0, 1.0);
}

/// D_i de N asas de mesma envergadura, área total e sustentação dividida igual, sobre o D_i de uma asa só com a
/// mesma envergadura e área. O arrasto induzido de um sistema de n asas é a soma das n² parcelas
/// σ_ij L_i L_j / (π q b²), com σ_ii = 1 (Prandtl, NACA TN 182, p. 3). Com L_i = L/N e as asas empilhadas a G uma
/// da outra (o par i, j a |i − j| G):
///   D_i,N / D_i,1 = (N + 2 Σ_{k=1}^{N−1} (N − k) σ(k G/b)) / N²
/// N = 1 dá 1 e N = 2 dá (1 + σ)/2, o biplano de Prandtl. Pelo teorema do escalonamento de Munk o recuo entre as
/// asas não muda o total, então uma asa atrás da outra entra com o desnível entre elas
pub fn wingsInducedFactor(wing_count: u32, gap_ratio: f64) f64 {
    if (wing_count <= 1) return 1.0;
    const count: f64 = @floatFromInt(wing_count);
    var total: f64 = count;
    for (1..wing_count) |k| {
        const distance: f64 = @floatFromInt(k);
        total += 2.0 * (count - distance) * pairSigma(distance * gap_ratio);
    }
    return total / (count * count);
}

/// asas com empenagem: uma asa só ou N asas de mesma envergadura dividindo a área (`SizingCfg.wing_count`)
pub const Conventional = struct {
    pub const name: [:0]const u8 = "convencional";
    pub const tail = true;
    pub const hover: Hover = .none;
    /// quantas asas dividem a área
    pub fn wings(cfg: *const sizing_types.SizingCfg) u32 {
        return @intCast(std.math.clamp(cfg.wing_count, 1, 8));
    }
    /// fator sobre o K do arrasto induzido: a interferência entre as asas (Prandtl)
    pub fn inducedFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return wingsInducedFactor(wings(cfg), cfg.gap_ratio);
    }
    /// C_L,max da aeronave dividido pelo c_l,max do perfil
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return if (wings(cfg) > 1) 0.95 * cfg.clmax_factor else cfg.clmax_factor; // com mais de uma asa, a interferência tira um pouco do C_L,max
    }
    /// massa própria do tipo (kg), somada à do dimensionamento
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, _: f64) f64 {
        const links: f64 = @floatFromInt(wings(cfg) - 1);
        return 0.1 * cfg.fuselage_mass * links; // montantes e estais entre as asas
    }
    /// número de superfícies sustentadoras e de controle: as asas e a empenagem
    pub fn surfaces(cfg: *const sizing_types.SizingCfg) u32 {
        return wings(cfg) + 2;
    }
};

pub const FlyingWing = struct {
    pub const name: [:0]const u8 = "asa voadora";
    /// quantas asas dividem a área
    pub fn wings(_: *const sizing_types.SizingCfg) u32 {
        return 1;
    }
    pub const tail = false;
    pub const hover: Hover = .none;
    /// fator sobre o K do arrasto induzido deste tipo
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    /// C_L,max da aeronave dividido pelo c_l,max do perfil
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor * cfg.trim_clmax_factor; // equilibrar sem EH custa C_L
    }
    /// massa própria do tipo (kg), somada à do dimensionamento
    pub fn extraMass(_: *const sizing_types.SizingCfg, _: f64) f64 {
        return 0;
    }
    /// número de superfícies sustentadoras e de controle
    pub fn surfaces(_: *const sizing_types.SizingCfg) u32 {
        return 1;
    }
};

pub const Tailsitter = struct {
    pub const name: [:0]const u8 = "tailsitter";
    /// quantas asas dividem a área
    pub fn wings(_: *const sizing_types.SizingCfg) u32 {
        return 1;
    }
    pub const tail = false;
    pub const hover: Hover = .required;
    /// fator sobre o K do arrasto induzido deste tipo
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    /// C_L,max da aeronave dividido pelo c_l,max do perfil
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor * cfg.trim_clmax_factor;
    }
    /// massa própria do tipo (kg), somada à do dimensionamento
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, _: f64) f64 {
        return cfg.gear_mass * 0.5; // pés de pouso em vez de trem
    }
    /// número de superfícies sustentadoras e de controle
    pub fn surfaces(_: *const sizing_types.SizingCfg) u32 {
        return 1;
    }
};

pub const Vtol = struct {
    pub const name: [:0]const u8 = "VTOL";
    /// quantas asas dividem a área
    pub fn wings(_: *const sizing_types.SizingCfg) u32 {
        return 1;
    }
    pub const tail = true;
    pub const hover: Hover = .optional;
    /// fator sobre o K do arrasto induzido deste tipo
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    /// C_L,max da aeronave dividido pelo c_l,max do perfil
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor;
    }
    /// massa própria do tipo (kg), somada à do dimensionamento
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, sets_mass: f64) f64 {
        return cfg.vtol_mass_frac * sets_mass; // braços e suportes dos motores de sustentação
    }
    /// número de superfícies sustentadoras e de controle
    pub fn surfaces(_: *const sizing_types.SizingCfg) u32 {
        return 3;
    }
};

/// na ordem de `types.AircraftKind`
pub const all = .{ Conventional, FlyingWing, Tailsitter, Vtol };

/// confere em comptime que `K` tem a interface de um tipo de aeronave
pub fn check(comptime Kind: type) void {
    inline for (.{ "name", "wings", "tail", "hover", "inducedFactor", "clmaxFactor", "extraMass", "surfaces" }) |decl_name| {
        if (!@hasDecl(Kind, decl_name)) @compileError("tipo de aeronave " ++ @typeName(Kind) ++ " sem `" ++ decl_name ++ "`");
    }
    if (@TypeOf(Kind.hover) != Hover) @compileError(@typeName(Kind) ++ ".hover tem de ser kinds.Hover");
    _ = @as(fn (*const sizing_types.SizingCfg) u32, Kind.wings);
    _ = @as(fn (*const sizing_types.SizingCfg) u32, Kind.surfaces);
    _ = @as(fn (*const sizing_types.SizingCfg) f64, Kind.inducedFactor);
    _ = @as(fn (*const sizing_types.SizingCfg) f64, Kind.clmaxFactor);
    _ = @as(fn (*const sizing_types.SizingCfg, f64) f64, Kind.extraMass);
}

comptime {
    for (all) |Kind| check(Kind);
    for (@typeInfo(sizing_types.AircraftKind).@"enum".fields, 0..) |field, i| {
        if (field.value != i or !std.mem.eql(u8, field.name, switch (i) {
            0 => "conventional",
            1 => "flying_wing",
            2 => "tailsitter",
            3 => "vtol",
            else => unreachable,
        })) @compileError("types.AircraftKind fora da ordem de kinds.all");
    }
}

const testing = std.testing;

test "N asas: σ cai com o vão; uma asa dá 1, duas dão o biplano de Prandtl, mais asas ganham menos" {
    try testing.expect(pairSigma(0.1) > pairSigma(0.3));
    var cfg: sizing_types.SizingCfg = .{};
    cfg.gap_ratio = 0.15;
    try testing.expectEqual(@as(f64, 1.0), Conventional.inducedFactor(&cfg));
    cfg.wing_count = 2;
    const two = Conventional.inducedFactor(&cfg);
    try testing.expectEqual(0.5 * (1.0 + pairSigma(0.15)), two); // (1 + σ)/2
    try testing.expectApproxEqAbs(@as(f64, 0.78), two, 0.01); // σ ≈ 0,56 em G/b = 0,15
    cfg.wing_count = 3;
    const three = Conventional.inducedFactor(&cfg);
    try testing.expect(three < two and three > 0.5);
    try testing.expectEqual(@as(u32, 5), Conventional.surfaces(&cfg));
}

test "todos os tipos têm a interface (comptime) e nomes distintos" {
    inline for (all, 0..) |Kind, i| {
        inline for (all, 0..) |Other, j| {
            if (i != j) try testing.expect(!std.mem.eql(u8, Kind.name, Other.name));
        }
    }
}
