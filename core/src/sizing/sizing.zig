//! Dimensionamento inicial (mini-MDO) no núcleo: avalia um vetor de projeto e otimiza.
//!
//!   eval(cfg, x)                    → SizingOut (grandezas, violação, curva de tração e arrasto)
//!   optimize(cfg, opts, buf)        → o melhor, e cada avaliação em `buf` (o gráfico de indivíduos)
//!
//! O tipo de aeronave (`cfg.kind`) e o otimizador (`opts.method`) chegam como números e viram tipos
//! Zig aqui (`inline for` sobre `kinds.all` e `optimize.all`): cada combinação é compilada à parte.
const std = @import("std");
const core_types = @import("../types.zig");
const sizing_types = @import("types.zig");
const chain = @import("chain.zig");
const kinds = @import("kinds.zig");
const optimizer = @import("optimize.zig");
pub const ground = @import("ground.zig");
pub const motorprop = @import("motorprop.zig");

pub const types = sizing_types;

/// avalia `design_vars` com a tração do núcleo (`params`: um Params de trabalho, só env/prop[0] são usados)
pub fn eval(cfg: *const sizing_types.SizingCfg, params: *core_types.Params, design_vars: []const f64) sizing_types.SizingOut {
    var thrust: chain.CoreThrust = .{ .p = params, .rho = cfg.rho };
    inline for (kinds.all, 0..) |Kind, i| {
        if (cfg.kind == i) return chain.Chain(Kind, chain.CoreThrust).eval(cfg, &thrust, design_vars);
    }
    return chain.Chain(kinds.all[0], chain.CoreThrust).eval(cfg, &thrust, design_vars);
}

/// nota usada pelo otimizador: a pontuação penalizada pela violação das restrições
pub fn fitness(result: *const sizing_types.SizingOut, penalty: f64) f64 {
    const score = if (std.math.isFinite(result.score)) result.score else -1e6;
    return score - penalty * result.violation * (1.0 + @abs(score));
}

const Ctx = struct {
    cfg: *const sizing_types.SizingCfg,
    p: *core_types.Params,
    penalty: f64,

    fn evaluate(ctx: *anyopaque, design_vars: []const f64) optimizer.Eval {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const result = eval(self.cfg, self.p, design_vars);
        var ind: sizing_types.Individual = .{ .x = result.x, .feasible = result.feasible, .score = result.score, .violation = result.violation, .mtow = result.q[sizing_types.q_mtow], .ee = result.q[sizing_types.q_ee], .pv = result.q[sizing_types.q_pv] };
        ind.fitness = fitness(&result, self.penalty);
        return .{ .fitness = ind.fitness, .ind = ind };
    }
};

/// roda o otimizador escolhido em `opts`, grava as avaliações em `buf` e o melhor em `best`
pub fn optimize(cfg: *const sizing_types.SizingCfg, opts: *const sizing_types.OptOpts, params: *core_types.Params, buf: []sizing_types.Individual, evaluated: *usize, best: *sizing_types.SizingOut, progress: ?optimizer.Progress, pctx: ?*anyopaque) void {
    var ctx: Ctx = .{ .cfg = cfg, .p = params, .penalty = opts.penalty };
    const problem: optimizer.Problem = .{ .ctx = &ctx, .specs = &cfg.vars, .evalFn = Ctx.evaluate };
    var rec: optimizer.Recorder = .{ .buf = buf, .progress = progress, .progress_ctx = pctx };
    const outcome = optimizer.run(problem, opts, &rec);
    evaluated.* = rec.n;
    best.* = eval(cfg, params, &outcome.best);
}

/// nomes para o Python montar os índices: 0 grandezas, 1 variáveis, 2 tipos de aeronave, 3 otimizadores
pub fn name(what: i32, index: i32) ?[*:0]const u8 {
    if (index < 0) return null;
    const position: usize = @intCast(index);
    switch (what) {
        0 => return if (position < sizing_types.n_q) sizing_types.q_names[position].ptr else null,
        1 => return if (position < sizing_types.n_vars) sizing_types.var_names[position].ptr else null,
        2 => {
            inline for (kinds.all, 0..) |Kind, j| if (j == position) return Kind.name.ptr;
            return null;
        },
        3 => {
            inline for (optimizer.all, 0..) |Optimizer, j| if (j == position) return Optimizer.name.ptr;
            return null;
        },
        else => return null,
    }
}

test {
    _ = @import("kinds.zig");
    _ = @import("stages.zig");
    _ = @import("chain.zig");
    _ = @import("optimize.zig");
    _ = @import("ground.zig");
    _ = @import("motorprop.zig");
}

test "nomes para o Python" {
    try std.testing.expectEqualStrings("mtow", std.mem.span(name(0, sizing_types.q_mtow).?));
    try std.testing.expectEqualStrings("biplano", std.mem.span(name(2, sizing_types.kind_biplane).?));
    try std.testing.expect(name(2, 99) == null and name(3, 0) != null);
}
