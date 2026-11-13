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
//! Efeito solo pelo método das imagens (`groundCoefficients`): o chão é um plano onde o ar não atravessa, e isso se
//! consegue com uma malha espelhada no plano, com a circulação trocada de sinal (Katz e Plotkin, "Low-Speed
//! Aerodynamics", método das imagens, a conferir no PDF). Para a imagem valer, a geometria é que gira pelo α em torno
//! do ponto de referência, e o vento fica na horizontal: girar o vento deixaria a asa na posição errada em relação
//! ao chão. As pernas livres saem na horizontal, ao longo do vento, e as da imagem também. Longe do chão a conta
//! volta à do VLM sem chão (com a esteira no vento, e não no corpo).
//!
//! Nada aloca: quem chama passa a malha, a matriz e os vetores (`Buffers`), com o tamanho de `panelCount`.
const std = @import("std");
const numerics = @import("../numerics.zig");
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
    pub fn normal(panel: *const Panel, control: f64) V3 {
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

pub const Error = error{ NoPanels, TooSmall, Singular, BelowGround };

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
    return if (target.group != source.group) numerics.active.vortex_core_fraction * source.chord else 0;
}

/// a ferradura `source` (Γ = 1) induzida em `point`; com o chão em z = `ground_z` (corpo girado, z para baixo), soma a
/// imagem: os nós espelhados no plano e a circulação trocada de sinal
fn influence(point: V3, source: *const Panel, include_bound: bool, core_radius: f64, ground_z: ?f64) V3 {
    const induced = llt.horseshoe(point, source.a, source.b, trailing, include_bound, core_radius);
    const plane = ground_z orelse return induced;
    return induced - llt.horseshoe(point, mirror(source.a, plane), mirror(source.b, plane), trailing, true, core_radius);
}

/// o ponto espelhado no plano z = `plane`
fn mirror(point: V3, plane: f64) V3 {
    return .{ point[0], point[1], 2 * plane - point[2] };
}

/// a matriz de influência w_ij · n_i, fatorada (LU com pivô parcial) em `matrix`
pub fn factor(panels: []const Panel, matrix: []f64, pivots: []usize) Error!void {
    return factorWith(panels, null, matrix, pivots);
}

/// a matriz de influência com o chão em z = `ground_z` (null: sem chão), fatorada em `matrix`
fn factorWith(panels: []const Panel, ground_z: ?f64, matrix: []f64, pivots: []usize) Error!void {
    const count = panels.len;
    if (matrix.len < count * count or pivots.len < count) return error.TooSmall;
    for (panels, 0..) |*target, i| {
        for (panels, 0..) |*source, j| {
            const induced = influence(target.control, source, true, coreRadius(target, source), ground_z);
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
    substitute(matrix, pivots, gamma[0..count]);
}

/// resolve no lugar o sistema já fatorado por `factor`: `gamma` entra com V_r · n de cada painel e sai com Γ
pub fn substitute(matrix: []const f64, pivots: []const usize, gamma: []f64) void {
    const count = gamma.len;
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
    return loadsWith(panels, gamma, velocity, null);
}

/// `loads` com o chão em z = `ground_z` (null: sem chão): a velocidade local inclui a induzida pelas imagens
fn loadsWith(panels: []const Panel, gamma: []const f64, velocity: V3, ground_z: ?f64) Loads {
    var out: Loads = .{};
    for (panels, 0..) |*target, i| {
        const middle = (target.a + target.b) * vec.splat(0.5);
        var air = -velocity;
        for (panels, 0..) |*source, j| {
            if (gamma[j] == 0) continue;
            air += influence(middle, source, i != j, coreRadius(target, source), ground_z) * vec.splat(gamma[j]);
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

/// os coeficientes em `alpha` com o ponto de referência `ref` a `height` m acima do chão (método das imagens; ver o
/// cabeçalho). Uma malha que encosta no chão (a menos de 5 % da corda do painel) é recusada (`BelowGround`). `height` infinita: sem chão, mas com a geometria girada e a esteira no vento. Os momentos são em
/// torno de `ref`; C_L e C_Di nos eixos do vento
pub fn groundCoefficients(params: *const types.Params, grid: Grid, alpha: f64, height: f64, ref: V3, buffers: Buffers) Error!Coefficients {
    return groundCoefficientsWith(params, grid, alpha, height, ref, vec.zero, buffers);
}

/// `groundCoefficients` com os comandos `deflections` (δe, δa, δr em rad, como `solve`)
pub fn groundCoefficientsWith(params: *const types.Params, grid: Grid, alpha: f64, height: f64, ref: V3, deflections: V3, buffers: Buffers) Error!Coefficients {
    const panels = try lattice(params, grid, buffers.panels);
    const count = panels.len;
    if (buffers.gamma.len < count) return error.TooSmall;
    // girar o avião por α em torno de ref, com o nariz para cima: a velocidade do avião vira (1, 0, 0)
    const turn = fmath.sincos(alpha);
    for (panels) |*panel| {
        panel.a = pitchAbout(panel.a, ref, turn.c, turn.s);
        panel.b = pitchAbout(panel.b, ref, turn.c, turn.s);
        panel.control = pitchAbout(panel.control, ref, turn.c, turn.s);
        panel.chord_dir = pitchAbout(panel.chord_dir, vec.zero, turn.c, turn.s);
        panel.up = pitchAbout(panel.up, vec.zero, turn.c, turn.s);
    }
    const ground_z: ?f64 = if (std.math.isFinite(height)) ref[2] + height else null;
    // a malha não pode encostar no chão: o vórtice e a imagem dele se anulam e a matriz fica singular
    if (ground_z) |plane| for (panels) |*panel| {
        const clearance = 0.05 * panel.chord;
        if (panel.a[2] > plane - clearance or panel.b[2] > plane - clearance or panel.control[2] > plane - clearance) return error.BelowGround;
    };
    try factorWith(panels, ground_z, buffers.matrix, buffers.pivots);
    const gamma = buffers.gamma[0..count];
    const velocity = V3{ 1, 0, 0 };
    solve(params, panels, buffers.matrix, buffers.pivots, velocity, deflections, gamma);
    return coefficients(params, loadsWith(panels, gamma, velocity, ground_z), 0, 0, ref);
}

/// o ponto girado em arfagem em torno de `pivot` (cosseno e seno de α): x' = c x + s z, z' = −s x + c z
fn pitchAbout(point: V3, pivot: V3, cosine: f64, sine: f64) V3 {
    const relative = point - pivot;
    return pivot + V3{ cosine * relative[0] + sine * relative[2], relative[1], -sine * relative[0] + cosine * relative[2] };
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


test "VLM com chão: sem chão e em α = 0 é o VLM de sempre; longe do chão volta a ele" {
    var params: types.Params = undefined;
    rectangularWing(&params, 16, 1.2, 0.2);
    var panels: [16 * 4]Panel = undefined;
    var matrix: [64 * 64]f64 = undefined;
    var pivots: [64]usize = undefined;
    var gamma: [64]f64 = undefined;
    const buffers: Buffers = .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma };
    const grid: Grid = .{ .chordwise = 4, .spanwise = 1 };
    const free = try derivatives(&params, grid, 0.0, vec.zero, buffers);
    const level = try groundCoefficients(&params, grid, 0.0, std.math.inf(f64), vec.zero, buffers);
    try testing.expectEqual(free.at.CL, level.CL);
    try testing.expectEqual(free.at.Cm, level.Cm);
    // em α a esteira vai no vento (aqui) e não no corpo (no VLM de sempre): em α = 0,1 rad a diferença é de ~2 %
    const tilted = try derivatives(&params, grid, 0.1, vec.zero, buffers);
    const away = try groundCoefficients(&params, grid, 0.1, std.math.inf(f64), vec.zero, buffers);
    try testing.expectApproxEqRel(tilted.at.CL, away.CL, 0.03);
    // a 50 envergaduras do chão a imagem quase não pesa
    const far = try groundCoefficients(&params, grid, 0.1, 60.0, vec.zero, buffers);
    try testing.expectApproxEqRel(away.CL, far.CL, 1e-4);
    try testing.expectApproxEqRel(away.CDi, far.CDi, 1e-3);
}

test "VLM com chão: perto do chão a sustentação sobe e o induzido por C_L² cai" {
    var params: types.Params = undefined;
    rectangularWing(&params, 16, 1.2, 0.2);
    var panels: [16 * 4]Panel = undefined;
    var matrix: [64 * 64]f64 = undefined;
    var pivots: [64]usize = undefined;
    var gamma: [64]f64 = undefined;
    const buffers: Buffers = .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma };
    const grid: Grid = .{ .chordwise = 4, .spanwise = 1 };
    const away = try groundCoefficients(&params, grid, 0.08, std.math.inf(f64), vec.zero, buffers);
    var previous_lift = away.CL;
    var previous_ratio = away.CDi / (away.CL * away.CL);
    for ([_]f64{ 0.6, 0.24, 0.12 }) |height| { // h/b = 0,5; 0,2; 0,1
        const near = try groundCoefficients(&params, grid, 0.08, height, vec.zero, buffers);
        const ratio = near.CDi / (near.CL * near.CL);
        try testing.expect(near.CL > previous_lift);
        try testing.expect(ratio < previous_ratio);
        previous_lift = near.CL;
        previous_ratio = ratio;
    }
}

test "VLM com chão: o momento picador vem quase todo da cauda, que perde o downwash perto do chão" {
    // asa 1,5 m × 0,25 m e cauda 0,5 m × 0,15 m a 0,8 m atrás, na mesma altura; CG em 1/4 da corda da asa
    var params: types.Params = undefined;
    rectangularWing(&params, 12, 1.5, 0.25);
    const wing_only = params;
    const tail_strips = 6;
    for (0..tail_strips) |i| {
        const y0 = -0.25 + 0.5 * @as(f64, @floatFromInt(i)) / tail_strips;
        const y1 = -0.25 + 0.5 * @as(f64, @floatFromInt(i + 1)) / tail_strips;
        const side: i32 = if (0.5 * (y0 + y1) > 0) 1 else -1;
        const x = -0.8 - 0.25 * 0.15;
        params.surf[12 + i] = .{
            .r = .{ x, 0.5 * (y0 + y1), 0 },
            .S = (y1 - y0) * 0.15,
            .c = 0.15,
            .CLa = 4.5,
            .group = .htail,
            .side = side,
            .qa = .{ x, if (side > 0) y0 else y1, 0 },
            .qb = .{ x, if (side > 0) y1 else y0, 0 },
        };
    }
    params.n_surf = 12 + tail_strips;
    @import("../physics/aero.zig").init(&params);
    var panels: [18 * 4]Panel = undefined;
    var matrix: [72 * 72]f64 = undefined;
    var pivots: [72]usize = undefined;
    var gamma: [72]f64 = undefined;
    const buffers: Buffers = .{ .panels = &panels, .matrix = &matrix, .pivots = &pivots, .gamma = &gamma };
    const grid: Grid = .{ .chordwise = 4, .spanwise = 1 };
    const reference = V3{ -0.0625, 0, 0 };
    const alpha = 8 * fmath.pi / 180.0;
    var heights: [24]f64 = undefined;
    var with_tail: [24]f64 = undefined;
    var without_tail: [24]f64 = undefined;
    var lift_change: [24]f64 = undefined;
    const free = try groundCoefficients(&params, grid, alpha, std.math.inf(f64), reference, buffers);
    const free_wing = try groundCoefficients(&wing_only, grid, alpha, std.math.inf(f64), reference, buffers);
    for (&heights, &with_tail, &without_tail, &lift_change, 0..) |*ratio, *full, *bare, *lift, i| {
        ratio.* = 0.1 + 0.04 * @as(f64, @floatFromInt(i)); // h/b
        const near = try groundCoefficients(&params, grid, alpha, ratio.* * 1.5, reference, buffers);
        const near_wing = try groundCoefficients(&wing_only, grid, alpha, ratio.* * 1.5, reference, buffers);
        full.* = near.Cm - free.Cm;
        bare.* = near_wing.Cm - free_wing.Cm;
        lift.* = near.CL - free.CL;
    }
    // perto do chão o avião inteiro pica (ΔC_m < 0) bem mais que a asa sozinha: a cauda perde o downwash
    try testing.expect(with_tail[0] < 0);
    try testing.expect(with_tail[0] < 2 * without_tail[0]);
    try @import("../util/plot.zig").fromTest("solo_delta_cm", .{ .title = "ΔC_m do chão em α = 8°", .x_label = "h/b", .y_label = "ΔC_m", .series = &.{
        .{ .label = "asa e cauda", .x = &heights, .y = &with_tail },
        .{ .label = "só a asa", .x = &heights, .y = &without_tail },
        .{ .label = "ΔC_L / 10", .x = &heights, .y = &tenth(lift_change) },
    } });
}

/// uma cópia dividida por 10 (para caber no mesmo gráfico)
fn tenth(values: [24]f64) [24]f64 {
    var out = values;
    for (&out) |*value| value.* /= 10;
    return out;
}
