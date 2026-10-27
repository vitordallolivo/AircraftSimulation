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
const sizing_types = @import("types.zig");

pub const Eval = struct {
    fitness: f64, // o que o otimizador maximiza (pontuação − penalidade)
    ind: sizing_types.Individual, // o que fica registrado (x usado, pontuação, violação...)
};

pub const Problem = struct {
    ctx: *anyopaque,
    specs: []const sizing_types.VarSpec,
    evalFn: *const fn (ctx: *anyopaque, design_vars: []const f64) Eval,

    /// avalia um ponto pela função do problema
    pub fn eval(self: Problem, design_vars: []const f64) Eval {
        return self.evalFn(self.ctx, design_vars);
    }
    /// número de variáveis do problema
    pub fn dim(self: Problem) usize {
        return self.specs.len;
    }
    /// faixa de amostragem: inteiros e listas cobrem os extremos com a mesma chance
    pub fn range(self: Problem, i: usize) [2]f64 {
        const spec = self.specs[i];
        const lo = @min(spec.lo, spec.hi);
        const hi = @max(spec.lo, spec.hi);
        if (spec.kind == sizing_types.var_continuous or lo == hi) return .{ lo, hi };
        const il = @ceil(lo);
        const ih = @max(@floor(hi), il);
        return .{ il - 0.499, ih + 0.499 };
    }
};

/// guarda cada avaliação (para o gráfico de indivíduos) até a capacidade do buffer
/// chamada ao fim de cada iteração (tempo real na GUI): devolve 0 para continuar, ≠ 0 para parar
pub const Progress = *const fn (ctx: ?*anyopaque, iter: i32, recorded: usize) callconv(.c) i32;

pub const Recorder = struct {
    buf: []sizing_types.Individual,
    n: usize = 0,
    evals: usize = 0,
    progress: ?Progress = null,
    progress_ctx: ?*anyopaque = null,
    stopped: bool = false,

    /// fim da iteração `iter`: avisa quem acompanha; falso = pediram para parar
    pub fn iteration(self: *Recorder, iter: usize) bool {
        if (self.progress) |callback| {
            if (callback(self.progress_ctx, @intCast(iter), self.n) != 0) self.stopped = true;
        }
        return !self.stopped;
    }

    /// conta a avaliação e a guarda no buffer, se ainda couber
    pub fn add(self: *Recorder, evaluation: Eval, iter: usize, particle: usize) void {
        self.evals += 1;
        if (self.n >= self.buf.len) return;
        var ind = evaluation.ind;
        ind.iter = @intCast(iter);
        ind.particle = @intCast(particle);
        ind.fitness = evaluation.fitness;
        self.buf[self.n] = ind;
        self.n += 1;
    }
};

pub const Result = struct {
    best: [sizing_types.n_vars]f64 = [_]f64{0} ** sizing_types.n_vars,
    fitness: f64 = -std.math.inf(f64),
    best_ind: sizing_types.Individual = .{},
};

fn keep(result: *Result, design_vars: []const f64, evaluation: Eval) void {
    if (evaluation.fitness > result.fitness) {
        result.fitness = evaluation.fitness;
        @memcpy(result.best[0..design_vars.len], design_vars);
        result.best_ind = evaluation.ind;
        result.best_ind.fitness = evaluation.fitness;
    }
}

fn rng(opts: *const sizing_types.OptOpts) std.Random.DefaultPrng {
    const seed: u64 = if (std.math.isFinite(opts.seed)) @intFromFloat(@abs(@round(opts.seed))) else 1;
    return std.Random.DefaultPrng.init(seed);
}

// ------------------------------------------------------------------ PSO (enxame, melhor global)
pub const Pso = struct {
    pub const name: [:0]const u8 = "PSO (enxame de partículas)";
    const max_p = 256;

    /// enxame com melhor global: velocidade puxada pelo melhor da partícula e pelo do enxame
    pub fn run(problem: Problem, opts: *const sizing_types.OptOpts, rec: *Recorder) Result {
        var result: Result = .{};
        const dims = problem.dim();
        const particle_count: usize = @intCast(std.math.clamp(opts.particles, 2, max_p));
        const iteration_count: usize = @intCast(std.math.clamp(opts.iterations, 1, 10000));
        var prng = rng(opts);
        const rand = prng.random();
        var pos: [max_p][sizing_types.n_vars]f64 = undefined;
        var vel: [max_p][sizing_types.n_vars]f64 = undefined;
        var pbest: [max_p][sizing_types.n_vars]f64 = undefined;
        var pfit: [max_p]f64 = undefined;
        for (0..particle_count) |k| {
            for (0..dims) |i| {
                const bounds = problem.range(i);
                pos[k][i] = bounds[0] + rand.float(f64) * (bounds[1] - bounds[0]);
                vel[k][i] = (rand.float(f64) - 0.5) * 0.2 * (bounds[1] - bounds[0]);
            }
            const evaluation = problem.eval(pos[k][0..dims]);
            rec.add(evaluation, 0, k);
            pbest[k] = pos[k];
            pfit[k] = evaluation.fitness;
            keep(&result, pos[k][0..dims], evaluation);
        }
        if (!rec.iteration(0)) return result;
        for (1..iteration_count) |it| {
            for (0..particle_count) |k| {
                for (0..dims) |i| {
                    const bounds = problem.range(i);
                    const span = bounds[1] - bounds[0];
                    const r1 = rand.float(f64);
                    const r2 = rand.float(f64);
                    var velocity = opts.w * vel[k][i] + opts.c1 * r1 * (pbest[k][i] - pos[k][i]) + opts.c2 * r2 * (result.best[i] - pos[k][i]);
                    velocity = std.math.clamp(velocity, -0.5 * span, 0.5 * span);
                    vel[k][i] = velocity;
                    pos[k][i] = std.math.clamp(pos[k][i] + velocity, bounds[0], bounds[1]);
                }
                const evaluation = problem.eval(pos[k][0..dims]);
                rec.add(evaluation, it, k);
                if (evaluation.fitness > pfit[k]) {
                    pfit[k] = evaluation.fitness;
                    pbest[k] = pos[k];
                }
                keep(&result, pos[k][0..dims], evaluation);
            }
            if (!rec.iteration(it)) break;
        }
        return result;
    }
};

// ------------------------------------------------------------------ busca aleatória (referência)
pub const RandomSearch = struct {
    pub const name: [:0]const u8 = "busca aleatória";

    /// sorteia pontos uniformes nas faixas e fica com o melhor
    pub fn run(problem: Problem, opts: *const sizing_types.OptOpts, rec: *Recorder) Result {
        var result: Result = .{};
        const dims = problem.dim();
        const sample_count: usize = @intCast(std.math.clamp(opts.particles, 1, 100000));
        const iteration_count: usize = @intCast(std.math.clamp(opts.iterations, 1, 10000));
        var prng = rng(opts);
        const rand = prng.random();
        var candidate: [sizing_types.n_vars]f64 = undefined;
        for (0..iteration_count) |it| {
            for (0..sample_count) |k| {
                for (0..dims) |i| {
                    const bounds = problem.range(i);
                    candidate[i] = bounds[0] + rand.float(f64) * (bounds[1] - bounds[0]);
                }
                const evaluation = problem.eval(candidate[0..dims]);
                rec.add(evaluation, it, k);
                keep(&result, candidate[0..dims], evaluation);
            }
            if (!rec.iteration(it)) break;
        }
        return result;
    }
};

/// na ordem de `method_*` (types.zig)
pub const all = .{ Pso, RandomSearch };

/// confere em comptime que `Optimizer` tem a interface de um otimizador
pub fn check(comptime Optimizer: type) void {
    if (!@hasDecl(Optimizer, "name") or !@hasDecl(Optimizer, "run")) @compileError("otimizador " ++ @typeName(Optimizer) ++ " sem `name` ou `run`");
    _ = @as(fn (Problem, *const sizing_types.OptOpts, *Recorder) Result, Optimizer.run);
}

comptime {
    for (all) |Optimizer| check(Optimizer);
}

/// roda o método `opts.method`
pub fn run(problem: Problem, opts: *const sizing_types.OptOpts, rec: *Recorder) Result {
    inline for (all, 0..) |Optimizer, i| {
        if (opts.method == i) return Optimizer.run(problem, opts, rec);
    }
    return all[0].run(problem, opts, rec);
}

// ------------------------------------------------------------------ testes: funções analíticas (rápidos)
const testing = std.testing;
const fuzz = @import("../util/fuzz.zig");

/// esfera deslocada com uma variável inteira e uma de lista: máximo em (1.3, −0.7, 3, 2)
const Sphere = struct {
    specs: [4]sizing_types.VarSpec = .{ .{ .lo = -5, .hi = 5 }, .{ .lo = -5, .hi = 5 }, .{ .lo = 0, .hi = 6, .kind = sizing_types.var_integer }, .{ .lo = 0, .hi = 4, .kind = sizing_types.var_list } },
    calls: usize = 0,

    fn evaluate(ctx: *anyopaque, design_vars: []const f64) Eval {
        const self: *Sphere = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const target = [_]f64{ 1.3, -0.7, 3, 2 };
        var sum_sq: f64 = 0;
        var ind: sizing_types.Individual = .{};
        for (design_vars, 0..) |value, i| {
            const rounded = if (self.specs[i].kind == sizing_types.var_continuous) value else @round(value);
            ind.x[i] = rounded;
            sum_sq += (rounded - target[i]) * (rounded - target[i]);
        }
        ind.score = -sum_sq;
        return .{ .fitness = -sum_sq, .ind = ind };
    }
    fn problem(self: *Sphere) Problem {
        return .{ .ctx = self, .specs = &self.specs, .evalFn = evaluate };
    }
};

test "PSO acha o máximo da esfera (contínuas, inteira e lista)" {
    var sphere: Sphere = .{};
    var buf: [2000]sizing_types.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    const opts: sizing_types.OptOpts = .{ .particles = 20, .iterations = 60, .seed = 3 };
    const result = Pso.run(sphere.problem(), &opts, &rec);
    try testing.expect(result.fitness > -1e-3);
    try testing.expectEqual(@as(f64, 3), result.best_ind.x[2]);
    try testing.expectEqual(@as(f64, 2), result.best_ind.x[3]);
    try testing.expectEqual(@as(usize, 20 * 60), rec.evals);
    try testing.expectEqual(rec.evals, sphere.calls);
}

test "a interface troca o método; a mesma semente dá o mesmo resultado" {
    var sphere: Sphere = .{};
    var buf: [600]sizing_types.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    var opts: sizing_types.OptOpts = .{ .particles = 10, .iterations = 30, .seed = 5, .method = sizing_types.method_random };
    const first = run(sphere.problem(), &opts, &rec);
    rec.n = 0;
    const second = run(sphere.problem(), &opts, &rec);
    try testing.expectEqual(first.fitness, second.fitness);
    opts.method = sizing_types.method_pso;
    rec.n = 0;
    const swarm = run(sphere.problem(), &opts, &rec);
    try testing.expect(swarm.fitness >= first.fitness); // o enxame não perde da busca aleatória com o mesmo orçamento
}

fn fuzzOpt(_: void, src: *fuzz.Src) !void {
    var sphere: Sphere = .{};
    for (&sphere.specs) |*spec| {
        spec.lo = src.range(-10, 10);
        spec.hi = spec.lo + src.range(0, 10);
    }
    var buf: [64]sizing_types.Individual = undefined;
    var rec: Recorder = .{ .buf = &buf };
    const opts: sizing_types.OptOpts = .{ .particles = @intCast(src.int(u32, 0, 12)), .iterations = @intCast(src.int(u32, 0, 8)), .seed = src.range(0, 1e6), .method = @intCast(src.int(u32, 0, 1)), .w = src.range(0, 1.2), .c1 = src.range(0, 3), .c2 = src.range(0, 3) };
    _ = run(sphere.problem(), &opts, &rec);
    // nenhum ponto avaliado sai dos limites (inteiros e listas arredondados dentro deles)
    for (buf[0..rec.n]) |ind| {
        for (0..4) |i| {
            const spec = sphere.specs[i];
            errdefer std.debug.print("i={d} x={d} lo={d} hi={d} kind={d}\n", .{ i, ind.x[i], spec.lo, spec.hi, spec.kind });
            const lo = if (spec.kind == sizing_types.var_continuous or spec.lo == spec.hi) spec.lo else @ceil(spec.lo);
            const hi = if (spec.kind == sizing_types.var_continuous or spec.lo == spec.hi) spec.hi else @max(@floor(spec.hi), @ceil(spec.lo));
            try testing.expect(ind.x[i] >= lo - 1e-9 and ind.x[i] <= hi + 1e-9);
        }
    }
    try testing.expect(rec.n <= buf.len);
}

test "progresso por iteração e parada pedida de fora" {
    const Count = struct {
        fn onIteration(ctx: ?*anyopaque, iter: i32, recorded: usize) callconv(.c) i32 {
            const counter: *[2]usize = @ptrCast(@alignCast(ctx.?));
            counter[0] += 1;
            counter[1] = recorded;
            return if (iter >= 4) 1 else 0; // para depois da 5ª iteração
        }
    };
    var cnt = [2]usize{ 0, 0 };
    var sphere: Sphere = .{};
    var buf: [400]sizing_types.Individual = undefined;
    inline for (all) |Optimizer| {
        cnt = .{ 0, 0 };
        var rec: Recorder = .{ .buf = &buf, .progress = Count.onIteration, .progress_ctx = &cnt };
        const opts: sizing_types.OptOpts = .{ .particles = 6, .iterations = 50 };
        _ = Optimizer.run(sphere.problem(), &opts, &rec);
        try testing.expectEqual(@as(usize, 5), cnt[0]);
        try testing.expectEqual(@as(usize, 30), cnt[1]); // 5 iterações × 6
    }
}

test "fuzz: otimizadores com limites e opções quaisquer" {
    try fuzz.check({}, fuzzOpt, .{});
}
