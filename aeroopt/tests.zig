//! Os testes sem janela da interface do aeroopt: a rodada de exemplo, o problema (`.opt.json`), o catálogo das
//! entradas e os resumos da esquerda.
test {
    _ = @import("opt_example.zig");
    _ = @import("problem.zig");
    _ = @import("inputs.zig");
    _ = @import("summary.zig");
}
