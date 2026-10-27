//! Documentação do núcleo do aerosim (`zig build docs`): todas as pastas de `core/src`, uma por seção.
//! A ABI C fica em `root.zig` (as `export fn`, com o `///` de cada uma); aqui estão os tipos e as funções em Zig.

pub const types = @import("types.zig");
pub const limits = @import("limits.zig");
pub const abi = @import("abi.zig");
pub const opt = @import("opt.zig");

/// vetores, matrizes, polinômios e funções rápidas (LUT)
pub const math = struct {
    pub const fmath = @import("math/fmath.zig");
    pub const linalg = @import("math/linalg.zig");
    pub const poly = @import("math/poly.zig");
    pub const vec = @import("math/vec.zig");
};

/// aerodinâmica, propulsão, massas, trem, atmosfera e terreno
pub const physics = struct {
    pub const aero = @import("physics/aero.zig");
    pub const aeromodel = @import("physics/aeromodel.zig");
    pub const aerotable = @import("physics/aerotable.zig");
    pub const atmosphere = @import("physics/atmosphere.zig");
    pub const gear = @import("physics/gear.zig");
    pub const mass = @import("physics/mass.zig");
    pub const propulsion = @import("physics/propulsion.zig");
    pub const terrain = @import("physics/terrain.zig");
};

/// métodos da literatura ligáveis por avião (efeito solo, esteira, interferência)
pub const modifiers = struct {
    pub const flapmoment = @import("modifiers/flapmoment.zig");
    pub const ground = @import("modifiers/ground.zig");
    pub const mod = @import("modifiers/mod.zig");
    pub const slipstream = @import("modifiers/slipstream.zig");
    pub const types = @import("modifiers/types.zig");
    pub const wingpair = @import("modifiers/wingpair.zig");
};

/// tubo da esteira contra os painéis
pub const collision = struct {
    pub const collision = @import("collision/collision.zig");
};

/// guiagem, piloto automático e ajuste dos ganhos
pub const control = struct {
    pub const autopilot = @import("control/autopilot.zig");
    pub const autotune = @import("control/autotune.zig");
    pub const guidance = @import("control/guidance.zig");
};

/// vetor de estados, dinâmica, integração, trimagem, linearização e desempenho
pub const sim = struct {
    pub const dynamics = @import("sim/dynamics.zig");
    pub const envelope = @import("sim/envelope.zig");
    pub const linear = @import("sim/linear.zig");
    pub const runner = @import("sim/runner.zig");
    pub const simple_perf = @import("sim/simple_perf.zig");
    pub const state = @import("sim/state.zig");
    pub const trim = @import("sim/trim.zig");
};

/// linha sustentadora (cargas ao longo da envergadura)
pub const loads = struct {
    pub const llt = @import("loads/llt.zig");
};

/// dimensionamento inicial (mini-MDO)
pub const sizing = struct {
    pub const chain = @import("sizing/chain.zig");
    pub const ground = @import("sizing/ground.zig");
    pub const kinds = @import("sizing/kinds.zig");
    pub const motorprop = @import("sizing/motorprop.zig");
    pub const optimize = @import("sizing/optimize.zig");
    pub const sizing = @import("sizing/sizing.zig");
    pub const stages = @import("sizing/stages.zig");
    pub const types = @import("sizing/types.zig");
};

/// buscas do aeroopt (GA, CMA-ES, DE, RBF, amostragem, sensibilidade)
pub const optim = struct {
    pub const cmaes = @import("optim/cmaes.zig");
    pub const de = @import("optim/de.zig");
    pub const expr = @import("optim/expr.zig");
    pub const ga = @import("optim/ga.zig");
    pub const guided = @import("optim/guided.zig");
    pub const localfit = @import("optim/localfit.zig");
    pub const rbf = @import("optim/rbf.zig");
    pub const sampling = @import("optim/sampling.zig");
    pub const sensmethods = @import("optim/sensmethods.zig");
    pub const types = @import("optim/types.zig");
};

/// conferência do avião montado (hélice × peças, chão)
pub const geometry = struct {
    pub const geometry = @import("geometry/geometry.zig");
};

/// fuzzing dos testes
pub const util = struct {
    pub const fuzz = @import("util/fuzz.zig");
};
