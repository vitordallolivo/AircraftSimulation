//! testes do grupo "control" (zig build test-control)

test {
    _ = @import("control/guidance.zig");
    _ = @import("control/autotune.zig");
}
