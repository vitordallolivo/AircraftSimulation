//! testes do grupo "math" (zig build test-math)

test {
    _ = @import("math/fmath_test.zig");
    _ = @import("math/vec.zig");
    _ = @import("math/poly.zig");
}
