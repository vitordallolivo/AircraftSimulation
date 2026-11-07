//! Os testes sem janela da interface do aeroopt: a rodada de exemplo e o problema (`.opt.json`).
test {
    _ = @import("opt_example.zig");
    _ = @import("problem.zig");
}
