//! testes do grupo "sim" (zig build test-sim)

test {
    _ = @import("sim/tests.zig");
    _ = @import("sim/envelope.zig");
    _ = @import("sim/simple_perf.zig");
    _ = @import("abi.zig");
    _ = @import("bench.zig");
}
