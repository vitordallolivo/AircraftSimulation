//! testes do grupo "optim" (zig build test-optim): o programa da pontuação do aeroopt, as gerações e a álgebra linear
test {
    _ = @import("optim/expr.zig");
    _ = @import("optim/ga.zig");
    _ = @import("math/linalg.zig");
}
