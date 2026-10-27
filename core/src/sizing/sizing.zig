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

/// avalia `x` com a tração do núcleo (`p`: um Params de trabalho, só env/prop[0] são usados)
pub fn eval(cfg: *const sizing_types.SizingCfg, p: *core_types.Params, x: []const f64) sizing_types.SizingOut {
    var th: chain.CoreThrust = .{ .p = p, .rho = cfg.rho };
    inline for (kinds.all, 0..) |K, i| {
        if (cfg.kind == i) return chain.Chain(K, chain.CoreThrust).eval(cfg, &th, x);
    }
    return chain.Chain(kinds.all[0], chain.CoreThrust).eval(cfg, &th, x);
}

pub fn fitness(o: *const sizing_types.SizingOut, penalty: f64) f64 {
    const s = if (std.math.isFinite(o.score)) o.score else -1e6;
    return s - penalty * o.violation * (1.0 + @abs(s));
}

const Ctx = struct {
    cfg: *const sizing_types.SizingCfg,
    p: *core_types.Params,
    penalty: f64,

    fn f(ctx: *anyopaque, x: []const f64) optimizer.Eval {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const o = eval(self.cfg, self.p, x);
        var ind: sizing_types.Individual = .{ .x = o.x, .feasible = o.feasible, .score = o.score, .violation = o.violation, .mtow = o.q[sizing_types.q_mtow], .ee = o.q[sizing_types.q_ee], .pv = o.q[sizing_types.q_pv] };
        ind.fitness = fitness(&o, self.penalty);
        return .{ .fitness = ind.fitness, .ind = ind };
    }
};

pub fn optimize(cfg: *const sizing_types.SizingCfg, opts: *const sizing_types.OptOpts, p: *core_types.Params, buf: []sizing_types.Individual, n: *usize, best: *sizing_types.SizingOut, progress: ?optimizer.Progress, pctx: ?*anyopaque) void {
    var ctx: Ctx = .{ .cfg = cfg, .p = p, .penalty = opts.penalty };
    const pb: optimizer.Problem = .{ .ctx = &ctx, .specs = &cfg.vars, .evalFn = Ctx.f };
    var rec: optimizer.Recorder = .{ .buf = buf, .progress = progress, .progress_ctx = pctx };
    const r = optimizer.run(pb, opts, &rec);
    n.* = rec.n;
    best.* = eval(cfg, p, &r.best);
}

/// nomes para o Python montar os índices: 0 grandezas, 1 variáveis, 2 tipos de aeronave, 3 otimizadores
pub fn name(what: i32, i: i32) ?[*:0]const u8 {
    if (i < 0) return null;
    const k: usize = @intCast(i);
    switch (what) {
        0 => return if (k < sizing_types.n_q) sizing_types.q_names[k].ptr else null,
        1 => return if (k < sizing_types.n_vars) sizing_types.var_names[k].ptr else null,
        2 => {
            inline for (kinds.all, 0..) |K, j| if (j == k) return K.name.ptr;
            return null;
        },
        3 => {
            inline for (optimizer.all, 0..) |O, j| if (j == k) return O.name.ptr;
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
