//! Estol por estação: o VLM (`vlm.zig`) acoplado à polar 2D de cada estação no seu Reynolds, pela correção de α
//! ("decambering"). Cada estação ganha uma incógnita δ_j, que entra só no lado direito do VLM, como um α0 a mais
//! (a normal gira por α0 + δ). A matriz fatorada não muda, e cada iteração custa só substituições.
//!
//! O c_l do VLM numa estação sai da circulação somada na corda, c_l = 2 ΣΓ/(V c). Como o VLM é o de placa plana com a
//! normal girada por α0 + δ, o ângulo efetivo que a seção vê é α_ef = c_l/(2π) + α0 + δ. O α0 entra aqui do mesmo
//! jeito que entra no VLM: sem isso, um perfil curvo em α = 0 já pediria um δ. O resíduo de cada estação é
//!
//!     R_j(δ) = c_l2D(α_ef,j, Re_j) − c_l,j^VLM(δ)
//!
//! e Newton o zera, com o jacobiano exato da resposta do VLM (um lado direito por estação), busca linear e
//! continuação em α (o δ de um α é o chute do próximo). Depois do pico da polar, o c_l sai de Viterna e Corrigan, só
//! se a polar já passou do pico; se não passou, a estação marca `beyond_polar` e fica no último ponto, e o usuário
//! precisa da polar mais alta. Fora da faixa de Reynolds das polares, a estação usa a mais próxima e marca
//! `outside_reynolds`: nada é inventado.
//!
//! Fontes: van Dam, C. P., "The aerodynamic design of multi-element high-lift systems for transport airplanes",
//! Progress in Aerospace Sciences 38, 2002 (o método de correção de α); Gallay, S. e Laurendeau, E., "Nonlinear
//! generalized lifting-line coupling algorithms for pre/poststall flows", AIAA Journal 53(7), 2015 (o decambering com
//! Newton); Viterna, L. A. e Corrigan, R. D., "Fixed pitch rotor performance of large horizontal axis wind turbines",
//! NASA CP-2230, 1982 (o pós-estol). Números das equações a conferir nos PDFs.
const std = @import("std");
const types = @import("../types.zig");
const vec = @import("../math/vec.zig");
const fmath = @import("../math/fmath.zig");
const section = @import("../physics/section.zig");
const vlm = @import("vlm.zig");
const V3 = vec.V3;

const two_pi = 2 * fmath.pi;
const degree = fmath.pi / 180.0;

/// as polares de um perfil em vários Reynolds, em ordem crescente de Re (as do usuário, do XFLR5)
pub const Family = struct {
    reynolds: []const f64,
    polars: []const section.Polar,
};

/// as polares de cada faixa: `of_strip[strip]` é o índice em `families` (null: todas usam a primeira)
pub const Sections = struct {
    families: []const Family,
    of_strip: ?[]const usize = null,
};

/// o estado de uma estação (uma coluna de painéis na corda)
pub const Station = struct {
    cl: f64 = 0,
    alpha_effective: f64 = 0, // rad
    reynolds: f64 = 0,
    delta: f64 = 0, // rad
    stalled: bool = false, // α_ef passou do α do pico da polar
    beyond_polar: bool = false, // α_ef além do último ponto de uma polar que não passou do pico
    outside_reynolds: bool = false,
    span_position: f64 = 0, // y do ponto de controle sobre a semienvergadura de referência
};

/// a memória do método, de quem chama: `delta`, `residual`, `trial`, `pivots` e `stations` com o número de estações,
/// `jacobian` com o quadrado e `scratch` com o número de painéis
pub const Work = struct {
    delta: []f64,
    residual: []f64,
    trial: []f64,
    jacobian: []f64,
    pivots: []usize,
    scratch: []f64,
    stations: []Station,
};

/// um ponto: os coeficientes do avião, quantas iterações e se convergiu
pub const Point = struct {
    coefficients: vlm.Coefficients = .{},
    iterations: usize = 0,
    converged: bool = false,
    residual: f64 = 0,
};

/// o resultado de uma varredura em α
pub const Sweep = struct {
    lift_max: f64 = 0,
    alpha_max: f64 = 0, // rad
    /// o α em que a primeira estação estolou, e onde ela fica (y sobre a semienvergadura); null se nenhuma estolou
    alpha_onset: ?f64 = null,
    onset_station: ?usize = null,
    onset_position: f64 = 0,
};

pub const Error = vlm.Error || error{ NoPolars, NotConverged, SingularJacobian };

/// quantas estações a malha tem (uma por coluna de painéis na corda)
pub fn stationCount(params: *const types.Params, grid: vlm.Grid) usize {
    return vlm.panelCount(params, grid) / @max(grid.chordwise, 1);
}

/// o c_l (e a inclinação, /rad) de uma polar em `angle` (graus), com Viterna além do último ponto se ela passou do
/// pico; `beyond` diz se faltou polar
fn polarAt(polar: *const section.Polar, angle: f64, aspect_ratio: f64) struct { cl: f64, slope: f64, peak: f64, beyond: bool } {
    const count = polar.count;
    var peak_index: usize = 0;
    for (0..count) |i| if (polar.cl[i] > polar.cl[peak_index]) {
        peak_index = i;
    };
    const peak = polar.alpha[peak_index];
    if (angle <= polar.alpha[0]) return .{ .cl = polar.cl[0], .slope = 0, .peak = peak, .beyond = true };
    if (angle >= polar.alpha[count - 1]) {
        const last = count - 1;
        if (peak_index == last) return .{ .cl = polar.cl[last], .slope = 0, .peak = peak, .beyond = true };
        const value = viterna(polar.alpha[last] * degree, polar.cl[last], aspect_ratio, angle * degree);
        const ahead = viterna(polar.alpha[last] * degree, polar.cl[last], aspect_ratio, angle * degree + 1e-4);
        return .{ .cl = value, .slope = (ahead - value) / 1e-4, .peak = peak, .beyond = false };
    }
    var i: usize = 1;
    while (polar.alpha[i] < angle) i += 1;
    const span = polar.alpha[i] - polar.alpha[i - 1];
    const share = (angle - polar.alpha[i - 1]) / span;
    return .{
        .cl = polar.cl[i - 1] + share * (polar.cl[i] - polar.cl[i - 1]),
        .slope = (polar.cl[i] - polar.cl[i - 1]) / (span * degree),
        .peak = peak,
        .beyond = false,
    };
}

/// Viterna e Corrigan: c_l = A1 sen 2α + A2 cos²α/sen α, a partir do ponto (`stall_angle`, `stall_cl`), com
/// C_D,max = 1,11 + 0,018 AR
fn viterna(stall_angle: f64, stall_cl: f64, aspect_ratio: f64, angle: f64) f64 {
    const drag_max = 1.11 + 0.018 * aspect_ratio;
    const sine = @sin(stall_angle);
    const cosine = @cos(stall_angle);
    const first = 0.5 * drag_max;
    const second = (stall_cl - drag_max * sine * cosine) * sine / (cosine * cosine);
    const s = @sin(angle);
    const c = @cos(angle);
    return first * 2 * s * c + second * c * c / s;
}

/// o c_l 2D da família em `angle` (rad) e Reynolds `reynolds`: linear em Re entre as duas polares vizinhas
fn familyAt(family: Family, reynolds: f64, angle: f64, aspect_ratio: f64) struct { cl: f64, slope: f64, peak: f64, beyond: bool, outside: bool } {
    const count = family.polars.len;
    const degrees = angle / degree;
    if (count == 1 or reynolds <= family.reynolds[0] or reynolds >= family.reynolds[count - 1]) {
        const index: usize = if (count == 1 or reynolds <= family.reynolds[0]) 0 else count - 1;
        const only = polarAt(&family.polars[index], degrees, aspect_ratio);
        const outside = count > 1 or reynolds != family.reynolds[0];
        return .{ .cl = only.cl, .slope = only.slope, .peak = only.peak * degree, .beyond = only.beyond, .outside = outside };
    }
    var upper: usize = 1;
    while (family.reynolds[upper] < reynolds) upper += 1;
    const share = (reynolds - family.reynolds[upper - 1]) / (family.reynolds[upper] - family.reynolds[upper - 1]);
    const low = polarAt(&family.polars[upper - 1], degrees, aspect_ratio);
    const high = polarAt(&family.polars[upper], degrees, aspect_ratio);
    return .{
        .cl = low.cl + share * (high.cl - low.cl),
        .slope = low.slope + share * (high.slope - low.slope),
        .peak = (low.peak + share * (high.peak - low.peak)) * degree,
        .beyond = low.beyond or high.beyond,
        .outside = false,
    };
}

/// o lado direito com os δ das estações, resolvido em `gamma`
fn circulation(panels: []const vlm.Panel, buffers: vlm.Buffers, velocity: V3, chordwise: usize, delta: []const f64, gamma: []f64) void {
    for (panels, 0..) |*panel, i| {
        gamma[i] = vec.dot(velocity, panel.normal(-delta[i / chordwise]));
    }
    vlm.substitute(buffers.matrix, buffers.pivots, gamma[0..panels.len]);
}

/// o c_l de cada estação, 2 ΣΓ/c (|V| = 1)
fn stationLift(panels: []const vlm.Panel, chordwise: usize, gamma: []const f64, out: []f64) void {
    for (out, 0..) |*lift, station| {
        var sum: f64 = 0;
        for (0..chordwise) |k| sum += gamma[station * chordwise + k];
        lift.* = 2 * sum / panels[station * chordwise].chord;
    }
}

/// o resíduo de cada estação e o estado dela, com os δ de `delta`; devolve a maior |R|
fn evaluate(context: Context, delta: []const f64, residual: []f64, stations: []Station) f64 {
    circulation(context.panels, context.buffers, context.velocity, context.chordwise, delta, context.buffers.gamma);
    stationLift(context.panels, context.chordwise, context.buffers.gamma, residual);
    var largest: f64 = 0;
    for (stations, 0..) |*station, j| {
        const panel = &context.panels[j * context.chordwise];
        const surface = &context.params.surf[panel.strip];
        const family = context.sections.families[if (context.sections.of_strip) |map| map[panel.strip] else 0];
        const reynolds = section.reynolds(context.density, context.airspeed, panel.chord);
        const lift = residual[j];
        const effective = lift / two_pi + panel.zero_lift + delta[j];
        const found = familyAt(family, reynolds, effective, surface.AR);
        residual[j] = found.cl - lift;
        largest = @max(largest, @abs(residual[j]));
        station.* = .{
            .cl = lift,
            .alpha_effective = effective,
            .reynolds = reynolds,
            .delta = delta[j],
            .stalled = effective > found.peak,
            .beyond_polar = found.beyond,
            .outside_reynolds = found.outside,
            .span_position = if (context.params.bref > 0) 2 * @abs(panel.control[1]) / context.params.bref else 0,
        };
    }
    return largest;
}

/// a inclinação dc_l2D/dα_ef de cada estação no estado atual
fn slopeAt(context: Context, station: Station, index: usize) f64 {
    const panel = &context.panels[index * context.chordwise];
    const family = context.sections.families[if (context.sections.of_strip) |map| map[panel.strip] else 0];
    return familyAt(family, station.reynolds, station.alpha_effective, context.params.surf[panel.strip].AR).slope;
}

const Context = struct {
    params: *const types.Params,
    panels: []const vlm.Panel,
    buffers: vlm.Buffers,
    sections: Sections,
    velocity: V3,
    chordwise: usize,
    airspeed: f64,
    density: f64,
};

/// resolve um α com o chute que está em `work.delta` (zero na primeira vez); a malha e a fatoração já estão em
/// `buffers` (`vlm.lattice` e `vlm.factor`)
fn solvePoint(context: Context, alpha: f64, ref: V3, work: Work) Error!Point {
    const count = work.stations.len;
    const chordwise = context.chordwise;
    var largest = evaluate(context, work.delta, work.residual, work.stations);
    var result: Point = .{};
    var iteration: usize = 0;
    while (iteration < 40 and largest > 1e-7) : (iteration += 1) {
        // o jacobiano: dR_j/dδ_k = (s_j/(2π) − 1) dc_l,j/dδ_k + s_j [j = k]
        for (0..count) |k| {
            for (context.panels, 0..) |*panel, i| {
                if (i / chordwise != k) {
                    work.scratch[i] = 0;
                    continue;
                }
                // d(V · n(α0 + δ))/dδ, com n(θ) = up cos θ − chord sen θ
                const turn = fmath.sincos(panel.zero_lift + work.delta[k]);
                const derivative = -panel.up * vec.splat(turn.s) - panel.chord_dir * vec.splat(turn.c);
                work.scratch[i] = vec.dot(context.velocity, derivative);
            }
            vlm.substitute(context.buffers.matrix, context.buffers.pivots, work.scratch[0..context.panels.len]);
            for (0..count) |j| {
                var sum: f64 = 0;
                for (0..chordwise) |c| sum += work.scratch[j * chordwise + c];
                const lift_change = 2 * sum / context.panels[j * chordwise].chord;
                const slope = slopeAt(context, work.stations[j], j);
                work.jacobian[j * count + k] = (slope / two_pi - 1) * lift_change + (if (j == k) slope else 0);
            }
        }
        for (0..count) |j| work.trial[j] = -work.residual[j];
        if (!luSolve(work.jacobian[0 .. count * count], work.pivots[0..count], work.trial[0..count])) return error.SingularJacobian;
        // busca linear: metade do passo até a maior |R| cair
        var step: f64 = 1;
        const start = largest;
        var halvings: usize = 0;
        while (true) : (halvings += 1) {
            for (0..count) |j| work.scratch[j] = work.delta[j] + step * work.trial[j];
            const tried = evaluate(context, work.scratch[0..count], work.residual, work.stations);
            if (tried < start or halvings >= 8) {
                @memcpy(work.delta[0..count], work.scratch[0..count]);
                largest = tried;
                break;
            }
            step *= 0.5;
        }
    }
    result.iterations = iteration;
    result.residual = largest;
    result.converged = largest <= 1e-7;
    // os coeficientes do avião com os δ finais (a `evaluate` deixou o Γ deles em buffers.gamma)
    _ = evaluate(context, work.delta, work.residual, work.stations);
    const found = vlm.loads(context.panels, context.buffers.gamma, context.velocity);
    result.coefficients = vlm.coefficients(context.params, found, alpha, 0, ref);
    return result;
}

/// eliminação de Gauss com pivô parcial em `matrix` (n × n, linha a linha); `rhs` vira a solução. false se singular
fn luSolve(matrix: []f64, pivots: []usize, rhs: []f64) bool {
    const count = rhs.len;
    for (0..count) |column| {
        var best = column;
        for (column + 1..count) |row| {
            if (@abs(matrix[row * count + column]) > @abs(matrix[best * count + column])) best = row;
        }
        if (!(@abs(matrix[best * count + column]) > 1e-14)) return false;
        pivots[column] = best;
        if (best != column) {
            for (0..count) |k| std.mem.swap(f64, &matrix[column * count + k], &matrix[best * count + k]);
            std.mem.swap(f64, &rhs[column], &rhs[best]);
        }
        for (column + 1..count) |row| {
            const ratio = matrix[row * count + column] / matrix[column * count + column];
            if (ratio == 0) continue;
            for (column..count) |k| matrix[row * count + k] -= ratio * matrix[column * count + k];
            rhs[row] -= ratio * rhs[column];
        }
    }
    var row = count;
    while (row > 0) {
        row -= 1;
        for (row + 1..count) |k| rhs[row] -= matrix[row * count + k] * rhs[k];
        rhs[row] /= matrix[row * count + row];
    }
    return true;
}

/// monta e fatora a malha (a matriz não muda com α nem com δ)
fn prepare(params: *const types.Params, grid: vlm.Grid, buffers: vlm.Buffers) Error![]vlm.Panel {
    const panels = try vlm.lattice(params, grid, buffers.panels);
    try vlm.factor(panels, buffers.matrix, buffers.pivots);
    return panels;
}

/// o estol por estação num α (rad), a `airspeed` (m/s) e `density` (kg/m³), momentos em `ref`; o estado de cada
/// estação fica em `work.stations`
pub fn point(params: *const types.Params, grid: vlm.Grid, sections: Sections, alpha: f64, airspeed: f64, density: f64, ref: V3, buffers: vlm.Buffers, work: Work) Error!Point {
    if (sections.families.len == 0) return error.NoPolars;
    const panels = try prepare(params, grid, buffers);
    const count = panels.len / @max(grid.chordwise, 1);
    if (work.delta.len < count or work.stations.len < count or work.jacobian.len < count * count or work.scratch.len < panels.len) return error.TooSmall;
    @memset(work.delta[0..count], 0);
    const context: Context = .{ .params = params, .panels = panels, .buffers = buffers, .sections = sections, .velocity = vlm.velocityAt(alpha, 0), .chordwise = @max(grid.chordwise, 1), .airspeed = airspeed, .density = density };
    return solvePoint(context, alpha, ref, sliced(work, count));
}

/// os pedaços de `work` com `count` estações
fn sliced(work: Work, count: usize) Work {
    return .{
        .delta = work.delta[0..count],
        .residual = work.residual[0..count],
        .trial = work.trial[0..count],
        .jacobian = work.jacobian[0 .. count * count],
        .pivots = work.pivots[0..count],
        .scratch = work.scratch,
        .stations = work.stations[0..count],
    };
}

/// a varredura em α (`alphas` em ordem crescente, rad) com continuação: o C_L de cada α em `lift`, o C_L,max, o α dele
/// e onde e quando o estol começou
pub fn sweep(params: *const types.Params, grid: vlm.Grid, sections: Sections, alphas: []const f64, airspeed: f64, density: f64, ref: V3, buffers: vlm.Buffers, work: Work, lift: []f64) Error!Sweep {
    if (sections.families.len == 0) return error.NoPolars;
    const panels = try prepare(params, grid, buffers);
    const count = panels.len / @max(grid.chordwise, 1);
    if (work.delta.len < count or work.stations.len < count or work.jacobian.len < count * count or work.scratch.len < panels.len) return error.TooSmall;
    const own = sliced(work, count);
    @memset(own.delta, 0);
    var result: Sweep = .{ .lift_max = -std.math.inf(f64) };
    for (alphas, lift[0..alphas.len]) |alpha, *out| {
        const context: Context = .{ .params = params, .panels = panels, .buffers = buffers, .sections = sections, .velocity = vlm.velocityAt(alpha, 0), .chordwise = @max(grid.chordwise, 1), .airspeed = airspeed, .density = density };
        const found = try solvePoint(context, alpha, ref, own);
        out.* = found.coefficients.CL;
        if (found.coefficients.CL > result.lift_max) {
            result.lift_max = found.coefficients.CL;
            result.alpha_max = alpha;
        }
        if (result.alpha_onset == null) {
            for (own.stations, 0..) |station, j| {
                if (!station.stalled) continue;
                result.alpha_onset = alpha;
                result.onset_station = j;
                result.onset_position = station.span_position;
                break;
            }
        }
    }
    return result;
}
