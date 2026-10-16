//! testes do grupo "physics" (zig build test-physics)

test {
    _ = @import("physics/atmosphere.zig");
    _ = @import("physics/aero.zig");
    _ = @import("physics/propulsion.zig");
    _ = @import("physics/gear.zig");
    _ = @import("physics/mass.zig");
    _ = @import("physics/terrain.zig");
    _ = @import("modifiers/mod.zig");
    _ = @import("collision/collision.zig");
    _ = @import("loads/llt.zig");
}
