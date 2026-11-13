//! O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
//! que a ABI C de `root.zig` usa, sem passar pela ABI.
pub const types = @import("types.zig");
pub const limits = @import("limits.zig");
pub const methods = @import("methods.zig");
/// o refino numérico dos solvers (iterações, tolerâncias, passos): `numerics.active`
pub const numerics = @import("numerics.zig");
pub const interface = @import("interface.zig");
pub const runner = @import("sim/runner.zig");
pub const trim = @import("sim/trim.zig");
pub const envelope = @import("sim/envelope.zig");
pub const simple_perf = @import("sim/simple_perf.zig");
pub const gust = @import("sim/gust.zig");
pub const aero = @import("physics/aero.zig");
pub const section = @import("physics/section.zig");
pub const propulsion = @import("physics/propulsion.zig");
pub const wing_line = @import("sizing/wing_line.zig");
pub const tail = @import("sizing/tail.zig");
pub const constraints = @import("sizing/constraints.zig");
/// o dimensionamento inicial (mini-MDO): avaliar um vetor de projeto e otimizar
pub const sizing = @import("sizing/sizing.zig");
pub const modifiers = @import("modifiers/mod.zig");
pub const collision = @import("collision/collision.zig");
pub const geometry = @import("geometry/geometry.zig");
pub const llt = @import("loads/llt.zig");
pub const sweep = @import("loads/sweep.zig");
pub const trefftz = @import("loads/trefftz.zig");
/// o VLM do avião (ferraduras em malha corda × envergadura): coeficientes e derivadas do escoamento potencial
pub const vlm = @import("loads/vlm.zig");
/// V-n e rajada, esforços ao longo da envergadura, divergência e reversão, e flutter
pub const vn = @import("loads/vn.zig");
pub const internal_loads = @import("loads/internal.zig");
pub const aeroelastic = @import("loads/aeroelastic.zig");
pub const flutter = @import("loads/flutter.zig");
/// estol por estação: o VLM com a polar 2D de cada estação no seu Reynolds (correção de α)
pub const stall = @import("loads/stall.zig");
pub const vec = @import("math/vec.zig");
pub const autotune = @import("control/autotune.zig");
pub const linear = @import("sim/linear.zig");
pub const static_stability = @import("sim/static.zig");
pub const flight_modes = @import("sim/modes.zig");
pub const mass = @import("physics/mass.zig");
pub const state = @import("sim/state.zig");
/// estruturas: seção composta (EI, tensões e margens)
pub const structures = struct {
    pub const section = @import("structures/section.zig");
    pub const buckling = @import("structures/buckling.zig");
    pub const gear = @import("structures/gear.zig");
};
/// as buscas do núcleo: as do aeroopt e as de uma variável que os managers usam (bisseção, seção áurea, secante)
pub const optim = struct {
    pub const scalar = @import("optim/scalar.zig");
    pub const topology = @import("optim/topology.zig");
    pub const guided = @import("optim/guided.zig");
    pub const de = @import("optim/de.zig");
    pub const ga = @import("optim/ga.zig");
    pub const cmaes = @import("optim/cmaes.zig");
};
