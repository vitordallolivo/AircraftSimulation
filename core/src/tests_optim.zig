//! testes do grupo "optim" (zig build test-optim): o programa da pontuação do aeroopt, as gerações, o CMA-ES, a evolução diferencial, o modelo local, o substituto RBF, os métodos da sensibilidade, o hipercubo latino, a busca guiada pela falha e a álgebra linear
test {
    _ = @import("optim/expr.zig");
    _ = @import("optim/ga.zig");
    _ = @import("optim/cmaes.zig");
    _ = @import("optim/de.zig");
    _ = @import("optim/localfit.zig");
    _ = @import("optim/rbf.zig");
    _ = @import("optim/sensmethods.zig");
    _ = @import("optim/sampling.zig");
    _ = @import("optim/guided.zig");
    _ = @import("math/linalg.zig");
}
