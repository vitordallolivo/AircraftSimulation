//! testes do grupo "optim" (zig build test-optim): o programa da pontuação do aeroopt e a álgebra linear
test {
    _ = @import("optim/expr.zig");
    _ = @import("math/linalg.zig");
}
