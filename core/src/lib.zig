//! O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
//! que a ABI C de `root.zig` usa, sem passar pela ABI.
pub const types = @import("types.zig");
pub const limits = @import("limits.zig");
pub const runner = @import("sim/runner.zig");
pub const trim = @import("sim/trim.zig");
pub const aero = @import("physics/aero.zig");
pub const modifiers = @import("modifiers/mod.zig");
pub const collision = @import("collision/collision.zig");
pub const vec = @import("math/vec.zig");
pub const autotune = @import("control/autotune.zig");
pub const linear = @import("sim/linear.zig");
