//! Todos os testes do aerodrive que não precisam de janela (`zig build test`).
//! Fuzzing contínuo: `zig build test --fuzz` (cada módulo tem o seu `testing.fuzz`).
test {
    _ = @import("math/vec3.zig");
    _ = @import("model/airfoil.zig");
    _ = @import("model/aircraft.zig");
    _ = @import("model/skeleton.zig");
    _ = @import("camera/camera.zig");
    _ = @import("gfx/pose.zig");
    _ = @import("input/channels.zig");
    _ = @import("sim/mission.zig");
    _ = @import("sim/params.zig");
    _ = @import("sim/drive_manager.zig");
    _ = @import("world/field.zig");
}
