//! Tipos de aeronave do dimensionamento: cada um é um tipo Zig com a mesma interface, conferida em
//! comptime (`check`). A cadeia (`chain.Chain(Kind, Thrust)`) é gerada para cada tipo, sem `if` de
//! configuração no meio das contas.
//!
//! Interface de um tipo:
//!   name: [:0]const u8
//!   wings: comptime_int                          asas que dividem a área (biplano: 2)
//!   tail: bool                                   tem empenagem (massa e arrasto pela fração da asa)
//!   hover: Hover                                 .none | .optional (decola na vertical se der) | .required
//!   fn inducedFactor(cfg) f64                    multiplica K = 1/(π AR e) (biplano: (1 + σ)/2, Prandtl)
//!   fn clmaxFactor(cfg) f64                      C_L,max da aeronave / c_l,max do perfil
//!   fn extraMass(cfg, sets_mass) f64             massa própria do tipo (VTOL: estrutura dos motores de sustentação)
//!   fn surfaces() u32                            superfícies sustentadoras e de controle (para a restrição)
//!
//! Novo tipo: escreva o struct e ponha em `all`; a ABI e o Python passam a aceitá-lo pelo índice.
const std = @import("std");
const sizing_types = @import("types.zig");

pub const Hover = enum { none, optional, required };

pub const Monoplane = struct {
    pub const name: [:0]const u8 = "monoplano";
    pub const wings = 1;
    pub const tail = true;
    pub const hover: Hover = .none;
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor;
    }
    pub fn extraMass(_: *const sizing_types.SizingCfg, _: f64) f64 {
        return 0;
    }
    pub fn surfaces() u32 {
        return 3;
    }
};

/// σ de interferência entre as asas do biplano (Prandtl), pelo vão/envergadura G/b
pub fn biplaneSigma(gap_ratio: f64) f64 {
    const g = std.math.clamp(gap_ratio, 0.0, 1.0);
    return std.math.clamp((1.0 - 0.66 * g) / (1.055 + 3.7 * g), 0.0, 1.0);
}

pub const Biplane = struct {
    pub const name: [:0]const u8 = "biplano";
    pub const wings = 2;
    pub const tail = true;
    pub const hover: Hover = .none;
    /// mesma envergadura e área total: D_i do biplano / D_i do monoplano = (1 + σ)/2
    pub fn inducedFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return 0.5 * (1.0 + biplaneSigma(cfg.gap_ratio));
    }
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return 0.95 * cfg.clmax_factor; // a asa de baixo perde um pouco no C_L,max (interferência)
    }
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, _: f64) f64 {
        return 0.1 * cfg.fuselage_mass; // montantes e estais
    }
    pub fn surfaces() u32 {
        return 4;
    }
};

pub const FlyingWing = struct {
    pub const name: [:0]const u8 = "asa voadora";
    pub const wings = 1;
    pub const tail = false;
    pub const hover: Hover = .none;
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor * cfg.trim_clmax_factor; // equilibrar sem EH custa C_L
    }
    pub fn extraMass(_: *const sizing_types.SizingCfg, _: f64) f64 {
        return 0;
    }
    pub fn surfaces() u32 {
        return 1;
    }
};

pub const Tailsitter = struct {
    pub const name: [:0]const u8 = "tailsitter";
    pub const wings = 1;
    pub const tail = false;
    pub const hover: Hover = .required;
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor * cfg.trim_clmax_factor;
    }
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, _: f64) f64 {
        return cfg.gear_mass * 0.5; // pés de pouso em vez de trem
    }
    pub fn surfaces() u32 {
        return 1;
    }
};

pub const Vtol = struct {
    pub const name: [:0]const u8 = "VTOL";
    pub const wings = 1;
    pub const tail = true;
    pub const hover: Hover = .optional;
    pub fn inducedFactor(_: *const sizing_types.SizingCfg) f64 {
        return 1.0;
    }
    pub fn clmaxFactor(cfg: *const sizing_types.SizingCfg) f64 {
        return cfg.clmax_factor;
    }
    pub fn extraMass(cfg: *const sizing_types.SizingCfg, sets_mass: f64) f64 {
        return cfg.vtol_mass_frac * sets_mass; // braços e suportes dos motores de sustentação
    }
    pub fn surfaces() u32 {
        return 3;
    }
};

/// na ordem dos índices `kind_*` de types.zig
pub const all = .{ Monoplane, Biplane, FlyingWing, Tailsitter, Vtol };

/// confere em comptime que `K` tem a interface de um tipo de aeronave
pub fn check(comptime K: type) void {
    inline for (.{ "name", "wings", "tail", "hover", "inducedFactor", "clmaxFactor", "extraMass", "surfaces" }) |d| {
        if (!@hasDecl(K, d)) @compileError("tipo de aeronave " ++ @typeName(K) ++ " sem `" ++ d ++ "`");
    }
    if (@TypeOf(K.hover) != Hover) @compileError(@typeName(K) ++ ".hover tem de ser kinds.Hover");
    if (K.wings < 1) @compileError(@typeName(K) ++ ".wings < 1");
    _ = @as(fn (*const sizing_types.SizingCfg) f64, K.inducedFactor);
    _ = @as(fn (*const sizing_types.SizingCfg) f64, K.clmaxFactor);
    _ = @as(fn (*const sizing_types.SizingCfg, f64) f64, K.extraMass);
}

comptime {
    for (all) |K| check(K);
}

const testing = std.testing;

test "biplano: σ cai com o vão; menos arrasto induzido que o monoplano de mesma envergadura" {
    try testing.expect(biplaneSigma(0.1) > biplaneSigma(0.3));
    var cfg: sizing_types.SizingCfg = .{};
    cfg.gap_ratio = 0.15;
    const f = Biplane.inducedFactor(&cfg);
    try testing.expect(f > 0.5 and f < 1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.78), f, 0.01); // σ ≈ 0,56 em G/b = 0,15
}

test "todos os tipos têm a interface (comptime) e nomes distintos" {
    inline for (all, 0..) |K, i| {
        inline for (all, 0..) |J, j| {
            if (i != j) try testing.expect(!std.mem.eql(u8, K.name, J.name));
        }
    }
}
