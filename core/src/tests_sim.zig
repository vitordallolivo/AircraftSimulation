//! testes do grupo "sim" (zig build test-sim)

test {
    _ = @import("sim/tests.zig");
    _ = @import("abi.zig");
    _ = @import("bench.zig");
}
