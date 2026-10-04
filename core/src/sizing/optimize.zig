//! Otimizadores do mini-MDO atrás de uma interface só.
//!
//! O problema chega como `Problem`: limites e tipo de cada variável e uma função que avalia um vetor
//! (devolve a aptidão — maior é melhor — e o que registrar). Não sabe nada de avião: os testes usam
//! funções analíticas e a cadeia usa `chain.Chain`.
//!
//! Interface de um otimizador (conferida em comptime por `check`):
//!   name: [:0]const u8
//!   fn run(problem: Problem, opts: *const OptOpts, rec: *Recorder) Result
//!
//! Novo otimizador (GA, Nelder-Mead, gradiente...): escreva o struct, ponha em `all` (o índice é o
//! `OptOpts.method`) e ele aparece para a ABI e para o Python.
const std = @import("std");
const S = @import("types.zig");

pub const Eval = struct {
    fitness: f64, // o que o otimizador maximiza (pontuação − penalidade)
    ind: S.Individual, // o que fica registrado (x usado, pontuação, violação...)
};

pub const Problem = struct {
    ctx: *anyopaque,
    specs: []const S.VarSpec,
    evalFn: *const fn (ctx: *anyopaque, x: []const f64) Eval,

    pub fn eval(self: Problem, x: []const f64) Eval {
        return self.evalFn(self.ctx, x);
    }
    pub fn dim(self: Problem) usize {
        return self.specs.len;
    }
    /// faixa de amostragem: inteiros e listas cobrem os extremos com a mesma chance
    pub fn range(self: Problem, i: usize) [2]f64 {
        const v = self.specs[i];
        const lo = @min(v.lo, v.hi);
        const hi = @max(v.lo, v.hi);
        if (v.kind == S.var_continuous or lo == hi) return .{ lo, hi };
        const il = @ceil(lo);
        const ih = @max(@floor(hi), il);
        return .{ il - 0.499, ih + 0.499 };
    }
};

/// guarda cada avaliação (para o gráfico de indivíduos) até a capacidade do buffer
/// chamada ao fim de cada iteração (tempo real na GUI): devolve 0 para continuar, ≠ 0 para parar
pub const Progress = *const fn (ctx: ?*anyopaque, iter: i32, n: usize) callconv(.c) i32;

pub const Recorder = struct {
    buf: []S.Individual,
    n: usize = 0,
    evals: usize = 0,
    progress: ?Progress = null,
    progress_ctx: ?*anyopaque = null,
    stopped: bool = false,

    /// fim da iteração `iter`: avisa quem acompanha; falso = pediram para parar
    pub fn iteration(self: *Recorder, iter: usize) bool {
        if (self.progress) |f| {
            if (f(self.progress_ctx, @intCast(iter), self.n) != 0) self.stopped = true;
        }
        return !self.stopped;
    }

    pub fn add(self: *Recorder, e: Eval, iter: usize, particle: usize) void {
        self.evals += 1;
        if (self.n >= self.buf.len) return;
        var ind = e.ind;
        ind.iter = @intCast(iter);
        ind.particle = @intCast(particle);
        ind.fitness = e.fitness;
        self.buf[self.n] = ind;
        self.n += 1;
    }
};

pub const Result = struct {
    best: [S.n_vars]f64 = [_]f64{0} ** S.n_vars,
    fitness: f64 = -std.math.inf(f64),
    best_ind: S.Individual = .{},
};

fn keep(r: *Result, x: []const f64, e: Eval) void {
    if (e.fitness > r.fitness) {
        r.fitness = e.fitness;
        @memcpy(r.best[0..x.len], x);
        r.best_ind = e.ind;
        r.best_ind.fitness = e.fitness;
    }
}

fn rng(opts: *const S.OptOpts) std.Random.DefaultPrng {
    const s: u64 = if (std.math.isFinite(opts.seed)) @intFromFloat(@abs(@round(opts.seed))) else 1;
    return std.Random.DefaultPrng.init(s);
}

// ------------------------------------------------------------------ PSO (enxame, melhor global)
pub const Pso = struct {
    pub const name: [:0]const u8 = "PSO (enxame de partículas)";
    const max_p = 256;

    pub fn run(pb: Problem, opts: *const S.OptOpts, rec: *Recorder) Result {
        var r: Result = .{};
        const n = pb.dim();
        const np: usize = @intCast(std.math.clamp(opts.particles, 2, max_p));
        const ni: usize = @intCast(std.math.clamp(opts.iterations, 1, 10000));
        var prng = rng(opts);
        const rand = prng.random();
        var pos: [max_p][S.n_vars]f64 = undefined;
        var vel: [max_p][S.n_vars]f64 = undefined;
        var pbest: [max_p][S.n_vars]f64 = undefined;
        var pfit: [max_p]f64 = undefined;
        for (0..np) |k| {
            for (0..n) |i| {
                const rg = pb.range(i);
                pos[k][i] = rg[0] + rand.float(f64) * (rg[1] - rg[0]);
                vel[k][i] = (rand.float(f64) - 0.5) * 0.2 * (rg[1] - rg[0]);
            }
            const e = pb.eval(pos[k][0..n]);
            rec.add(e, 0, k);
            pbest[k] = pos[k];
            pfit[k] = e.fitness;
            keep(&r, pos[k][0..n], e);
        }
        if (!rec.iteration(0)) return r;
        for (1..ni) |it| {
            for (0..np) |k| {
                for (0..n) |i| {
                    const rg = pb.range(i);
                    const span = rg[1] - rg[0];
                    const r1 = rand.float(f64);
                    const r2 = rand.float(f64);
                    var v = opts.w * vel[k][i] + opts.c1 * r1 * (pbest[k][i] - pos[k][i]) + opts.c2 * r2 * (r.best[i] - pos[k][i]);
                    v = std.math.clamp(v, -0.5 * span, 0.5 * span);
                    vel[k][i] = v;
                    pos[k][i] = std.math.clamp(pos[k][i] + v, rg[0], rg[1]);
                }
                const e = pb.eval(pos[k][0..n]);
                rec.add(e, it, k);
                if (e.fitness > pfit[k]) {
                    pfit[k] = e.fitness;
                    pbest[k] = pos[k];
                }
                keep(&r, pos[k][0..n], e);
            }
            if (!rec.iteration(it)) break;
        }
        return r;
    }
};

// ------------------------------------------------------------------ busca aleatória (referência)
pub const RandomSearch = struct {
    pub const name: [:0]const u8 = "busca aleatória";

    pub fn run(pb: Problem, opts: *const S.OptOpts, rec: *Recorder) Result {
        var r: Result = .{};
        const n = pb.dim();
        const np: usize = @intCast(std.math.clamp(opts.particles, 1, 100000));
        const ni: usize = @intCast(std.math.clamp(opts.iterations, 1, 10000));
        var prng = rng(opts);
        const rand = prng.random();
        var x: [S.n_vars]f64 = undefined;
        for (0..ni) |it| {
            for (0..np) |k| {
                for (0..n) |i| {
                    const rg = pb.range(i);
                    x[i] = rg[0] + rand.float(f64) * (rg[1] - rg[0]);
                }
                const e = pb.eval(x[0..n]);
                rec.add(e, it, k);
                keep(&r, x[0..n], e);
            }
            if (!rec.iteration(it)) break;
        }
        return r;
    }
};

/// na ordem de `method_*` (types.zig)
pub const all = .{ Pso, RandomSearch };

pub fn check(comptime O: type) void {
    if (!@hasDecl(O, "name") or !@hasDecl(O, "run")) @compileError("otimizador " ++ @typeName(O) ++ " sem `name` ou `run`");
    _ = @as(fn (Problem, *const S.OptOpts, *Recorder) Result, O.run);
}

comptime {
    for (all) |O| check(O);
}

/// roda o método `opts.method`
pub fn run(pb: Problem, opts: *const S.OptOpts, rec: *Recorder) Result {
    inline for (all, 0..) |O, i| {
        if (opts.method == i) return O.run(pb, opts, rec);
    }
    return all[0].run(pb, opts, rec);
}

// ------------------------------------------------------------------ testes: funções analíticas (rápidos)
const testing = std.testing;
const fz = @import("../util/fuzz.zig");

/// esfera deslocada com uma variável inteira e uma de lista: máximo em (1.3, −0.7, 3, 2)
const Sphere = struct {
    specs: [4]S.VarSpec = .{ .{ .lo = -5, .hi = 5 }, .{ .lo = -5, .hi = 5 }, .{ .lo = 0, .hi = 6, .kind = S.var_integer }, .{ .lo = 0, .hi = 4, .kind = S.var_list } },
    calls: usize = 0,

    fn f(ctx: *anyopaque, x: []const f64) Eval {
        const self: *Sphere = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const t = [_]f64{ 1.3, -0.7, 3, 2 };
        var s: f64 = 0;
        var ind: S.Individual = .{};
        for (x, 0..) |v, i| {
            const u = if (self.specs[i].kind == S.var_continuous) v else @round(v);
            ind.x[i] = u;
            s += (u - t[i]) * (u - t[i]);
        }
        ind.score = -s;
        return .{ .fitness = -s, .ind = ind };
    }
    fn problem(self: *Sphere) Problem {
        return .{ .ctx = self, .specs = &self.specs, .evalFn = f };
    }
};

test "PSO acha o máximo da esfera (contínuas, inteira e lista)" {
    var sp: Sphere = .{};
    var buf: [2000]S.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    const opts: S.OptOpts = .{ .particles = 20, .iterations = 60, .seed = 3 };
    const r = Pso.run(sp.problem(), &opts, &rec);
    try testing.expect(r.fitness > -1e-3);
    try testing.expectEqual(@as(f64, 3), r.best_ind.x[2]);
    try testing.expectEqual(@as(f64, 2), r.best_ind.x[3]);
    try testing.expectEqual(@as(usize, 20 * 60), rec.evals);
    try testing.expectEqual(rec.evals, sp.calls);
}

test "a interface troca o método; a mesma semente dá o mesmo resultado" {
    var sp: Sphere = .{};
    var buf: [600]S.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    var opts: S.OptOpts = .{ .particles = 10, .iterations = 30, .seed = 5, .method = S.method_random };
    const a = run(sp.problem(), &opts, &rec);
    rec.n = 0;
    const b = run(sp.problem(), &opts, &rec);
    try testing.expectEqual(a.fitness, b.fitness);
    opts.method = S.method_pso;
    rec.n = 0;
    const p = run(sp.problem(), &opts, &rec);
    try testing.expect(p.fitness >= a.fitness); // o enxame não perde da busca aleatória com o mesmo orçamento
}

fn fuzzOpt(_: void, src: *fz.Src) !void {
    var sp: Sphere = .{};
    for (&sp.specs) |*v| {
        v.lo = src.range(-10, 10);
        v.hi = v.lo + src.range(0, 10);
    }
    var buf: [64]S.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    const opts: S.OptOpts = .{ .particles = @intCast(src.int(u32, 0, 12)), .iterations = @intCast(src.int(u32, 0, 8)), .seed = src.range(0, 1e6), .method = @intCast(src.int(u32, 0, 1)), .w = src.range(0, 1.2), .c1 = src.range(0, 3), .c2 = src.range(0, 3) };
    _ = run(sp.problem(), &opts, &rec);
    // nenhum ponto avaliado sai dos limites (inteiros e listas arredondados dentro deles)
    for (buf[0..rec.n]) |ind| {
        for (0..4) |i| {
            const v = sp.specs[i];
            errdefer std.debug.print("i={d} x={d} lo={d} hi={d} kind={d}\n", .{ i, ind.x[i], v.lo, v.hi, v.kind });
            const lo = if (v.kind == S.var_continuous or v.lo == v.hi) v.lo else @ceil(v.lo);
            const hi = if (v.kind == S.var_continuous or v.lo == v.hi) v.hi else @max(@floor(v.hi), @ceil(v.lo));
            try testing.expect(ind.x[i] >= lo - 1e-9 and ind.x[i] <= hi + 1e-9);
        }
    }
    try testing.expect(rec.n <= buf.len);
}

test "progresso por iteração e parada pedida de fora" {
    const Count = struct {
        fn f(ctx: ?*anyopaque, iter: i32, n: usize) callconv(.c) i32 {
            const c: *[2]usize = @ptrCast(@alignCast(ctx.?));
            c[0] += 1;
            c[1] = n;
            return if (iter >= 4) 1 else 0; // para depois da 5ª iteração
        }
    };
    var cnt = [2]usize{ 0, 0 };
    var sp: Sphere = .{};
    var buf: [400]S.Individual = undefined;
    inline for (all) |O| {
        cnt = .{ 0, 0 };
        var rec: Recorder = .{ .buf = &buf, .progress = Count.f, .progress_ctx = &cnt };
        const opts: S.OptOpts = .{ .particles = 6, .iterations = 50 };
        _ = O.run(sp.problem(), &opts, &rec);
        try testing.expectEqual(@as(usize, 5), cnt[0]);
        try testing.expectEqual(@as(usize, 30), cnt[1]); // 5 iterações × 6
    }
}

test "fuzz: otimizadores com limites e opções quaisquer" {
    try fz.check({}, fuzzOpt, .{});
}
