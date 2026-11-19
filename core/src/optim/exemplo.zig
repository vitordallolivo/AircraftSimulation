//! O exemplo do README de `optim/`: o CMA-ES achando o ótimo de um problema de teste em três variáveis.
//! `cd core && python -m ziglang build exemplo -Dexemplo=optim`
const std = @import("std");
const cmaes = @import("aerosim").optim.cmaes;

pub fn main() !void {
    const dims = 3;
    var state: cmaes.CmaState = .{};
    cmaes.init(&state, dims, &.{ 0.2, 0.2, 0.2 }, 0.3, 0, 1); // média inicial, passo, λ padrão, semente
    const lambda: usize = @intCast(state.lambda);
    var points: [cmaes.max_lambda * dims]f64 = undefined;
    var scores: [cmaes.max_lambda]f64 = undefined;
    for (0..60) |_| {
        cmaes.ask(&state, points[0 .. lambda * dims]); // λ × n em [0, 1]
        for (0..lambda) |k| { // maior é melhor; o ótimo é 0,7 em cada variável
            scores[k] = 0;
            for (points[k * dims ..][0..dims]) |x| scores[k] -= (x - 0.7) * (x - 0.7);
        }
        cmaes.tell(&state, points[0 .. lambda * dims], scores[0..lambda]);
    }
    std.debug.print("média {d:.3} {d:.3} {d:.3}, passo {d:.5}\n", .{ state.mean[0], state.mean[1], state.mean[2], state.sigma });
}
