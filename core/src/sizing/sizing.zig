//! Dimensionamento inicial (mini-MDO) no núcleo: avalia um vetor de projeto e otimiza.
//!
//!   eval(cfg, x)                    → SizingOut (grandezas, violação, curva de tração e arrasto)
//!   optimize(cfg, opts, buf)        → o melhor, e cada avaliação em `buf` (o gráfico de indivíduos)
//!
//! O tipo de aeronave (`cfg.kind`) e o otimizador (`opts.method`) chegam como números e viram tipos
//! Zig aqui (`inline for` sobre `kinds.all` e `optimize.all`): cada combinação é compilada à parte.
const std = @import("std");
const T = @import("../types.zig");
const S = @import("types.zig");
const chain = @import("chain.zig");
const kinds = @import("kinds.zig");
const opt = @import("optimize.zig");
pub const ground = @import("ground.zig");

pub const types = S;

/// avalia `x` com a tração do núcleo (`p`: um Params de trabalho, só env/prop[0] são usados)
pub fn eval(cfg: *const S.SizingCfg, p: *T.Params, x: []const f64) S.SizingOut {
    var th: chain.CoreThrust = .{ .p = p, .rho = cfg.rho };
    inline for (kinds.all, 0..) |K, i| {
        if (cfg.kind == i) return chain.Chain(K, chain.CoreThrust).eval(cfg, &th, x);
    }
    return chain.Chain(kinds.all[0], chain.CoreThrust).eval(cfg, &th, x);
}

pub fn fitness(o: *const S.SizingOut, penalty: f64) f64 {
    const s = if (std.math.isFinite(o.score)) o.score else -1e6;
    return s - penalty * o.violation * (1.0 + @abs(s));
}

const Ctx = struct {
    cfg: *const S.SizingCfg,
    p: *T.Params,
    penalty: f64,

    fn f(ctx: *anyopaque, x: []const f64) opt.Eval {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const o = eval(self.cfg, self.p, x);
        var ind: S.Individual = .{ .x = o.x, .feasible = o.feasible, .score = o.score, .violation = o.violation, .mtow = o.q[S.q_mtow], .ee = o.q[S.q_ee], .pv = o.q[S.q_pv] };
        ind.fitness = fitness(&o, self.penalty);
        return .{ .fitness = ind.fitness, .ind = ind };
    }
};

pub fn optimize(cfg: *const S.SizingCfg, opts: *const S.OptOpts, p: *T.Params, buf: []S.Individual, n: *usize, best: *S.SizingOut, progress: ?opt.Progress, pctx: ?*anyopaque) void {
    var ctx: Ctx = .{ .cfg = cfg, .p = p, .penalty = opts.penalty };
    const pb: opt.Problem = .{ .ctx = &ctx, .specs = &cfg.vars, .evalFn = Ctx.f };
    var rec: opt.Recorder = .{ .buf = buf, .progress = progress, .progress_ctx = pctx };
    const r = opt.run(pb, opts, &rec);
    n.* = rec.n;
    best.* = eval(cfg, p, &r.best);
}

/// nomes para o Python montar os índices: 0 grandezas, 1 variáveis, 2 tipos de aeronave, 3 otimizadores
pub fn name(what: i32, i: i32) ?[*:0]const u8 {
    if (i < 0) return null;
    const k: usize = @intCast(i);
    switch (what) {
        0 => return if (k < S.n_q) S.q_names[k].ptr else null,
        1 => return if (k < S.n_vars) S.var_names[k].ptr else null,
        2 => {
            inline for (kinds.all, 0..) |K, j| if (j == k) return K.name.ptr;
            return null;
        },
        3 => {
            inline for (opt.all, 0..) |O, j| if (j == k) return O.name.ptr;
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
}

test "nomes para o Python" {
    try std.testing.expectEqualStrings("mtow", std.mem.span(name(0, S.q_mtow).?));
    try std.testing.expectEqualStrings("biplano", std.mem.span(name(2, S.kind_biplane).?));
    try std.testing.expect(name(2, 99) == null and name(3, 0) != null);
}
