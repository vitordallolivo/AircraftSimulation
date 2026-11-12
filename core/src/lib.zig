//! O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
//! que a ABI C de `root.zig` usa, sem passar pela ABI.
pub const types = @import("types.zig");
pub const limits = @import("limits.zig");
pub const methods = @import("methods.zig");
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
pub const vec = @import("math/vec.zig");
pub const autotune = @import("control/autotune.zig");
pub const linear = @import("sim/linear.zig");
pub const static_stability = @import("sim/static.zig");
pub const flight_modes = @import("sim/modes.zig");
pub const mass = @import("physics/mass.zig");
pub const state = @import("sim/state.zig");
/// as buscas do núcleo: as do aeroopt e as de uma variável que os managers usam (bisseção, seção áurea, secante)
pub const optim = struct {
    pub const scalar = @import("optim/scalar.zig");
    pub const topology = @import("optim/topology.zig");
    pub const guided = @import("optim/guided.zig");
    pub const de = @import("optim/de.zig");
    pub const ga = @import("optim/ga.zig");
    pub const cmaes = @import("optim/cmaes.zig");
};
