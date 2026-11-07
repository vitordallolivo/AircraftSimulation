//! Método dos vórtices em malha (VLM) do avião: cada faixa sustentadora do núcleo (`Params.surf`) vira uma malha de
//! painéis, alguns ao longo da corda e alguns ao longo da envergadura, cada um com uma ferradura. O segmento ligado
//! fica a 1/4 do painel, o ponto de controle a 3/4, e as pernas livres vão para trás ao longo de −x do corpo. Em cada
//! ponto de controle o ar não atravessa a superfície:
//!
//!     Σ_j Γ_j (w_ij · n_i) = V_r · n_i
//!
//! w_ij é a velocidade que a ferradura j, com Γ = 1, induz no ponto de controle i (Biot–Savart, `llt.horseshoe`).
//! V_r é a velocidade do avião em relação ao ar. A normal n_i é a da faixa girada pelo ângulo de sustentação nula da
//! seção, α0 = −C_L0/C_Lα (a placa plana equivalente), menos o comando. As forças saem de Kutta–Joukowski no
//! segmento ligado, F = ρ Γ (V_ar × l), com a velocidade local, que inclui a induzida. Por isso o arrasto também sai,
//! e é o induzido. Os coeficientes são do escoamento potencial: sem estol, sem atrito e sem a fuselagem.
//!
//! Fontes: Katz, J. e Plotkin, A., "Low-Speed Aerodynamics", 2ª ed., Cambridge, 2001, seção 12.3 (o VLM com
//! ferraduras e a condição a 3/4 do painel); Bertin, J. J. e Cummings, R. M., "Aerodynamics for Engineers", cap. 7
//! (o mesmo método, com ferraduras empilhadas na corda). Números das equações a conferir no PDF.
//!
//! As faixas guardam só a corda média. A corda em cada nó da linha de 1/4 é a média das faixas que dividem o nó; numa
//! ponta, ela sai da reta pela corda média da faixa (c_ponta = 2 c − c_outro nó). Entre grupos diferentes (asa e
//! cauda) os vórtices têm o núcleo de Scully da linha sustentadora (`llt.core_frac`), para a perna da asa não passar
//! em cima de um ponto de controle da cauda.
//!
//! Nada aloca: quem chama passa a malha, a matriz e os vetores (`Buffers`), com o tamanho de `panelCount`.
const std = @import("std");
const types = @import("../types.zig");
const limits = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const fmath = @import("../math/fmath.zig");
const llt = @import("llt.zig");
const V3 = vec.V3;

/// quantos painéis em cada faixa: ao longo da corda e ao longo da envergadura
pub const Grid = struct { chordwise: usize = 4, spanwise: usize = 1 };

/// um painel da malha: o segmento ligado (de `a` para `b`, Γ > 0 sustenta), o ponto de controle e a normal girada
pub const Panel = struct {
    a: V3,
    b: V3,
    control: V3,
    chord_dir: V3, // ex da faixa (ao longo da corda, para a frente)
    up: V3, // ez da faixa
    zero_lift: f64, // α0 da seção (rad)
    group: limits.Group,
    chord: f64, // corda da faixa ali (o núcleo dos vórtices entre grupos)
    strip: usize, // a faixa de onde veio (o comando dela)

    /// a normal girada por α0 e pelo comando: V_r · n = |V| sen(α_g − α0 + τ δ) (placa plana equivalente)
    fn normal(panel: *const Panel, control: f64) V3 {
        const turn = fmath.sincos(panel.zero_lift - control);
        return panel.up * vec.splat(turn.c) - panel.chord_dir * vec.splat(turn.s);
    }
};

/// a memória da conta, de quem chama: `panels` e `gamma` com `panelCount` itens, `matrix` com o quadrado e `pivots`
pub const Buffers = struct {
    panels: []Panel,
    matrix: []f64,
    pivots: []usize,
    gamma: []f64,
};

pub const Error = error{ NoPanels, TooSmall, Singular };

/// as forças e os momentos do avião (no corpo, com ρ = 1 e |V| = 1) e as forças por grupo
pub const Loads = struct {
    force: V3 = vec.zero,
    moment: V3 = vec.zero, // em torno da origem do corpo
    group_force: [limits.n_groups]V3 = [_]V3{vec.zero} ** limits.n_groups,
};

/// os coeficientes num α e num β (eixos do vento para C_L, C_D e C_Y; momentos no ponto de referência)
pub const Coefficients = struct {
    CL: f64 = 0,
    CDi: f64 = 0,
    CY: f64 = 0,
    Cl: f64 = 0,
    Cm: f64 = 0,
    Cn: f64 = 0,
    CL_wing: f64 = 0,
    CL_htail: f64 = 0,
};

/// as derivadas de estabilidade do VLM (por radiano) e o ponto neutro
pub const Derivatives = struct {
    at: Coefficients = .{}, // no α pedido
    CLa: f64 = 0,
    Cma: f64 = 0,
    CYb: f64 = 0,
    Clb: f64 = 0,
    Cnb: f64 = 0,
    /// k de C_Di = k C_L² (entre o α pedido e α + Δα); e = 1/(π AR k)
    induced_factor: f64 = 0,
    /// x do ponto neutro no corpo (m): onde dC_m/dα = 0
    neutral_x: f64 = 0,
    panels: usize = 0,
};

/// as faixas que entram (grupo, área e corda), sem a fuselagem
fn usable(surface: *const types.Surface) bool {
    return surface.group != .none and surface.group != .fuselage and surface.S > 0 and surface.c > 0;
}

/// quantos painéis a malha `grid` dá com as faixas de `params`
pub fn panelCount(params: *const types.Params, grid: Grid) usize {
    var count: usize = 0;
    const n_surf: usize = @intCast(@max(params.n_surf, 0));
    for (params.surf[0..n_surf]) |*surface| {
        if (usable(surface)) count += @max(grid.chordwise, 1) * @max(grid.spanwise, 1);
    }
    return count;
}

/// os nós de 1/4 de corda da faixa, na ordem da envergadura (`a` à esquerda de quem olha de trás; Γ > 0 sustenta)
fn stripNodes(surface: *const types.Surface) struct { a: V3, b: V3 } {
    const node = llt.surfaceNodes(surface);
    return .{ .a = node.A, .b = node.B };
}

/// a corda no nó `point`: a média das faixas que têm um nó ali, ou da reta pela corda média se só esta tem
fn nodeChord(params: *const types.Params, own: usize, point: V3, other: V3) f64 {
    const tolerance = 1e-9;
    const n_surf: usize = @intCast(@max(params.n_surf, 0));
    var total: f64 = 0;
    var count: f64 = 0;
    for (params.surf[0..n_surf]) |*surface| {
        if (!usable(surface)) continue;
        const node = stripNodes(surface);
        if (vec.norm(node.a - point) < tolerance or vec.norm(node.b - point) < tolerance) {
            total += surface.c;
            count += 1;
        }
    }
    const own_chord = params.surf[own].c;
    if (count > 1) return total / count;
    // a ponta: pela corda do outro nó da faixa, se ele tem vizinho
    var other_total: f64 = 0;
    var other_count: f64 = 0;
    for (params.surf[0..n_surf]) |*surface| {
        if (!usable(surface)) continue;
        const node = stripNodes(surface);
        if (vec.norm(node.a - other) < tolerance or vec.norm(node.b - other) < tolerance) {
            other_total += surface.c;
            other_count += 1;
        }
    }
    if (other_count < 2) return own_chord;
    const other_chord = other_total / other_count;
    return @max(2 * own_chord - other_chord, 0.2 * own_chord);
}

/// monta a malha em `out` (com `panelCount` itens)
pub fn lattice(params: *const types.Params, grid: Grid, out: []Panel) Error![]Panel {
    const chordwise = @max(grid.chordwise, 1);
    const spanwise = @max(grid.spanwise, 1);
    const count = panelCount(params, grid);
    if (count == 0) return error.NoPanels;
    if (out.len < count) return error.TooSmall;
    const n_surf: usize = @intCast(@max(params.n_surf, 0));
    var index: usize = 0;
    for (params.surf[0..n_surf], 0..) |*surface, strip| {
        if (!usable(surface)) continue;
        const node = stripNodes(surface);
        const chord_a = nodeChord(params, strip, node.a, node.b);
        const chord_b = nodeChord(params, strip, node.b, node.a);
        const ex = vec.v3(surface.ex); // ao longo da corda, para a frente
        const ez = vec.v3(surface.ez);
        const zero_lift = if (surface.CLa != 0) -surface.CL0 / surface.CLa else 0;
        for (0..spanwise) |s| {
            const t0 = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(spanwise));
            const t1 = @as(f64, @floatFromInt(s + 1)) / @as(f64, @floatFromInt(spanwise));
            const quarter_a = node.a + (node.b - node.a) * vec.splat(t0);
            const quarter_b = node.a + (node.b - node.a) * vec.splat(t1);
            const ca = chord_a + (chord_b - chord_a) * t0;
            const cb = chord_a + (chord_b - chord_a) * t1;
            const lead_a = quarter_a + ex * vec.splat(0.25 * ca);
            const lead_b = quarter_b + ex * vec.splat(0.25 * cb);
            for (0..chordwise) |k| {
                const bound = (@as(f64, @floatFromInt(k)) + 0.25) / @as(f64, @floatFromInt(chordwise));
                const check = (@as(f64, @floatFromInt(k)) + 0.75) / @as(f64, @floatFromInt(chordwise));
                const a = lead_a - ex * vec.splat(bound * ca);
                const b = lead_b - ex * vec.splat(bound * cb);
                const control = (lead_a - ex * vec.splat(check * ca) + lead_b - ex * vec.splat(check * cb)) * vec.splat(0.5);
                out[index] = .{
                    .a = a,
                    .b = b,
                    .control = control,
                    .chord_dir = ex,
                    .up = ez,
                    .zero_lift = zero_lift,
                    .group = surface.group,
                    .chord = 0.5 * (ca + cb),
                    .strip = strip,
                };
                index += 1;
            }
        }
    }
    return out[0..count];
}

/// as pernas livres saem para trás, ao longo de −x do corpo (a matriz não muda com α e β)
const trailing = V3{ -1, 0, 0 };

/// o núcleo de Scully entre grupos diferentes (`llt.core_frac` da corda de quem solta)
fn coreRadius(target: *const Panel, source: *const Panel) f64 {
    return if (target.group != source.group) llt.core_frac * source.chord else 0;
}

/// a matriz de influência w_ij · n_i, fatorada (LU com pivô parcial) em `matrix`
pub fn factor(panels: []const Panel, matrix: []f64, pivots: []usize) Error!void {
    const count = panels.len;
    if (matrix.len < count * count or pivots.len < count) return error.TooSmall;
    for (panels, 0..) |*target, i| {
        for (panels, 0..) |*source, j| {
            const induced = llt.horseshoe(target.control, source.a, source.b, trailing, true, coreRadius(target, source));
            matrix[i * count + j] = vec.dot(induced, target.normal(0));
        }
    }
    for (0..count) |column| {
        var best = column;
        var largest = @abs(matrix[column * count + column]);
        for (column + 1..count) |row| {
            const value = @abs(matrix[row * count + column]);
            if (value > largest) {
                largest = value;
                best = row;
            }
        }
        if (largest < 1e-14) return error.Singular;
        pivots[column] = best;
        if (best != column) for (0..count) |k| std.mem.swap(f64, &matrix[column * count + k], &matrix[best * count + k]);
        const pivot = matrix[column * count + column];
        for (column + 1..count) |row| {
            const ratio = matrix[row * count + column] / pivot;
            matrix[row * count + column] = ratio;
            if (ratio == 0) continue;
            for (column + 1..count) |k| matrix[row * count + k] -= ratio * matrix[column * count + k];
        }
    }
}

/// as circulações para a velocidade do avião `velocity` (corpo) e os comandos `deflections`
pub fn solve(params: *const types.Params, panels: []const Panel, matrix: []const f64, pivots: []const usize, velocity: V3, deflections: V3, gamma: []f64) void {
    const count = panels.len;
    for (panels, 0..) |*panel, i| {
        const surface = &params.surf[panel.strip];
        // o comando entra como um α0 a menos (τ δ); a matriz fica a de δ = 0 (ângulo pequeno)
        const control = surface.tau * vec.dot(vec.v3(surface.mix), deflections);
        gamma[i] = vec.dot(velocity, panel.normal(control));
    }
    for (0..count) |row| {
        std.mem.swap(f64, &gamma[row], &gamma[pivots[row]]);
        for (0..row) |k| gamma[row] -= matrix[row * count + k] * gamma[k];
    }
    var row = count;
    while (row > 0) {
        row -= 1;
        for (row + 1..count) |k| gamma[row] -= matrix[row * count + k] * gamma[k];
        gamma[row] /= matrix[row * count + row];
    }
}

/// Kutta–Joukowski em cada segmento ligado, com a velocidade local (a do voo mais a induzida no meio do segmento)
pub fn loads(panels: []const Panel, gamma: []const f64, velocity: V3) Loads {
    var out: Loads = .{};
    for (panels, 0..) |*target, i| {
        const middle = (target.a + target.b) * vec.splat(0.5);
        var air = -velocity;
        for (panels, 0..) |*source, j| {
            if (gamma[j] == 0) continue;
            air += llt.horseshoe(middle, source.a, source.b, trailing, i != j, coreRadius(target, source)) * vec.splat(gamma[j]);
        }
        const force = vec.cross(air, target.b - target.a) * vec.splat(gamma[i]);
        out.force += force;
        out.moment += vec.cross(middle, force);
        out.group_force[limits.groupIndex(target.group)] += force;
    }
    return out;
}

/// a velocidade do avião (|V| = 1) em α e β, como `llt.coeffs`
pub fn velocityAt(alpha: f64, beta: f64) V3 {
    const sa = fmath.sincos(alpha);
    const sb = fmath.sincos(beta);
    return .{ sa.c * sb.c, sb.s, sa.s * sb.c };
}

/// os coeficientes das forças `found` em α e β, com os momentos em `ref`
pub fn coefficients(params: *const types.Params, found: Loads, alpha: f64, beta: f64, ref: V3) Coefficients {
    const sa = fmath.sincos(alpha);
    const sb = fmath.sincos(beta);
    const qS = 0.5 * params.Sref;
    const force = found.force;
    const moment = found.moment - vec.cross(ref, force);
    const wing = found.group_force[limits.groupIndex(.wing)];
    const htail = found.group_force[limits.groupIndex(.htail)];
    return .{
        .CL = (-force[2] * sa.c + force[0] * sa.s) / qS,
        .CDi = -(force[0] * sa.c * sb.c + force[1] * sb.s + force[2] * sa.s * sb.c) / qS,
        .CY = force[1] / qS,
        .Cl = moment[0] / (qS * params.bref),
        .Cm = moment[1] / (qS * params.cref),
        .Cn = moment[2] / (qS * params.bref),
        .CL_wing = (-wing[2] * sa.c + wing[0] * sa.s) / qS,
        .CL_htail = (-htail[2] * sa.c + htail[0] * sa.s) / qS,
    };
}

/// monta, fatora e resolve: os coeficientes em `alpha` e as derivadas (diferença de 1° em α e em β), momentos em `ref`
pub fn derivatives(params: *const types.Params, grid: Grid, alpha: f64, ref: V3, buffers: Buffers) Error!Derivatives {
    const panels = try lattice(params, grid, buffers.panels);
    const count = panels.len;
    if (buffers.gamma.len < count) return error.TooSmall;
    try factor(panels, buffers.matrix, buffers.pivots);
    const gamma = buffers.gamma[0..count];
    const step = 1.0 * fmath.pi / 180.0;
    const cases = [_][2]f64{ .{ alpha, 0 }, .{ alpha + step, 0 }, .{ alpha, step } };
    var found: [3]Loads = undefined;
    var coefficient: [3]Coefficients = undefined;
    for (cases, 0..) |case, k| {
        const velocity = velocityAt(case[0], case[1]);
        solve(params, panels, buffers.matrix, buffers.pivots, velocity, vec.zero, gamma);
        found[k] = loads(panels, gamma, velocity);
        coefficient[k] = coefficients(params, found[k], case[0], case[1], ref);
    }
    const at = coefficient[0];
    const up = coefficient[1];
    const side = coefficient[2];
    // ponto neutro: M_P,y = M_O,y − (P_z F_x − P_x F_z); dM_P,y/dα = 0 dá P_x (P_z = z da referência)
    const d_force = (found[1].force - found[0].force) / vec.splat(step);
    const d_moment = (found[1].moment[1] - found[0].moment[1]) / step;
    const neutral_x = if (@abs(d_force[2]) > 1e-12) (ref[2] * d_force[0] - d_moment) / d_force[2] else std.math.nan(f64);
    const lift_change = up.CL * up.CL - at.CL * at.CL;
    return .{
        .at = at,
        .CLa = (up.CL - at.CL) / step,
        .Cma = (up.Cm - at.Cm) / step,
        .CYb = (side.CY - at.CY) / step,
        .Clb = (side.Cl - at.Cl) / step,
        .Cnb = (side.Cn - at.Cn) / step,
        .induced_factor = if (@abs(lift_change) > 1e-12) (up.CDi - at.CDi) / lift_change else std.math.nan(f64),
        .neutral_x = neutral_x,
        .panels = count,
    };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

/// asa retangular plana de envergadura `span` e corda `chord`, em `strips` faixas, centrada na origem
fn rectangularWing(params: *types.Params, strips: usize, span: f64, chord: f64) void {
    params.* = .{};
    params.n_surf = @intCast(strips);
    params.Sref = span * chord;
    params.cref = chord;
    params.bref = span;
    for (0..strips) |i| {
        const y0 = -0.5 * span + span * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(strips));
        const y1 = -0.5 * span + span * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(strips));
        const side: i32 = if (0.5 * (y0 + y1) > 0) 1 else -1;
        params.surf[i] = .{
            .r = .{ -0.25 * chord, 0.5 * (y0 + y1), 0 },
            .S = (y1 - y0) * chord,
            .c = chord,
            .CLa = 4.5,
            .side = side,
            .qa = .{ -0.25 * chord, if (side > 0) y0 else y1, 0 },
            .qb = .{ -0.25 * chord, if (side > 0) y1 else y0, 0 },
        };
    }
    @import("../physics/aero.zig").init(params);
}

test "VLM: asa retangular AR 6 com C_Lα perto de Helmbold e sem força lateral em β = 0" {
    var params: types.Params = undefined;
    rectangularWing(&params, 20, 1.2, 0.2);
    var panels: [20 * 4 * 2]Panel = undefined;
    var matrix: [160 * 160]f64 = undefined;
    var pivots: [160]usize = undefined;
    var gamma: [160]f64 = undefined;
    const found = try derivatives(&params, .{ .chordwise = 4, .spanwise = 2 }, 0.05, .{ 0, 0, 0 }, .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma });
    // Helmbold, AR 6: C_Lα = 2π/(√(1 + k²) + k), k = 2π/(π AR) = 1/3 → 4,53 /rad. O VLM dá uns 6 % menos na asa
    // retangular (4,23 com a malha fina); Helmbold é só uma aproximação
    try testing.expectApproxEqRel(@as(f64, 4.53), found.CLa, 0.08);
    try testing.expect(found.CLa < 4.53);
    try testing.expectApproxEqAbs(@as(f64, 0), found.at.CY, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), found.at.Cl, 1e-9);
    // o ponto neutro da asa sozinha fica perto de 1/4 da corda (x = −0,05 m)
    try testing.expectApproxEqAbs(@as(f64, -0.25 * 0.2), found.neutral_x, 0.01);
    // e = 1/(π AR k) perto de 1 numa asa retangular (≈ 0,9 a 1)
    const efficiency = 1 / (fmath.pi * 6 * found.induced_factor);
    try testing.expect(efficiency > 0.85 and efficiency < 1.05);
}

test "VLM: C_Lα converge com a malha" {
    var params: types.Params = undefined;
    rectangularWing(&params, 16, 1.2, 0.2);
    var panels: [16 * 8 * 3]Panel = undefined;
    var matrix: [384 * 384]f64 = undefined;
    var pivots: [384]usize = undefined;
    var gamma: [384]f64 = undefined;
    const buffers: Buffers = .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma };
    const coarse = try derivatives(&params, .{ .chordwise = 2, .spanwise = 1 }, 0.05, vec.zero, buffers);
    const middle = try derivatives(&params, .{ .chordwise = 4, .spanwise = 2 }, 0.05, vec.zero, buffers);
    const fine = try derivatives(&params, .{ .chordwise = 8, .spanwise = 3 }, 0.05, vec.zero, buffers);
    try testing.expect(@abs(fine.CLa - middle.CLa) < @abs(middle.CLa - coarse.CLa));
    try testing.expectApproxEqRel(fine.CLa, middle.CLa, 0.02);
}

test "VLM: asa enflechada de Bertin e Cummings (AR 5, Λ = 45°, 4 ferraduras na semienvergadura) dá C_Lα = 3,443" {
    // Bertin e Cummings, "Aerodynamics for Engineers", exemplo do VLM (cap. 7): C_Lα = 0,0601 /° = 3,443 /rad — a
    // conferir no PDF
    var params: types.Params = undefined;
    rectangularWing(&params, 8, 1.0, 0.2);
    for (params.surf[0..8]) |*surface| {
        surface.qa[0] = -0.25 * 0.2 - @abs(surface.qa[1]);
        surface.qb[0] = -0.25 * 0.2 - @abs(surface.qb[1]);
        surface.r[0] = -0.25 * 0.2 - @abs(surface.r[1]);
    }
    var panels: [8]Panel = undefined;
    var matrix: [8 * 8]f64 = undefined;
    var pivots: [8]usize = undefined;
    var gamma: [8]f64 = undefined;
    const found = try derivatives(&params, .{ .chordwise = 1, .spanwise = 1 }, 0, vec.zero, .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma });
    try testing.expectApproxEqRel(@as(f64, 3.443), found.CLa, 1e-3);
}

