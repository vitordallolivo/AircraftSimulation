//! Dispositivos de ponta de asa pelo arrasto induzido mínimo no plano de Trefftz (o par de
//! `aerosim/aero/tipdevices.py`).
//!
//! O arrasto induzido de qualquer sistema sustentador depende só do traço da esteira no plano de Trefftz e da
//! circulação Γ(s) ao longo dele (Munk, 1921; Kroo, "Drag due to lift: concepts for prediction and reduction", Annual
//! Review of Fluid Mechanics 33, 2001): L = ρ V ∮ Γ dy e D_i = −(ρ/2) ∮ Γ w_n ds, com w_n a velocidade normal que os
//! vórtices livres (dΓ/ds) induzem no traço. Com o traço em painéis de Γ constante, D_i = Γᵀ M Γ e L = bᵀ Γ; o mínimo
//! de D_i com L fixo é M Γ ∝ b (a condição de Munk). O fator de eficiência do vão é e = L² / (π q b² D_i) (asa plana
//! elíptica: e = 1). Referência (Kroo 2001, fig. 7, a conferir no PDF): asa em caixa com h/b = 0,2 → e ≈ 1,46.
//!
//! O estudo (`deviceStudy`) desconta o atrito da área molhada do dispositivo (ΔD/q = C_f S_molhada) e compara com
//! uma extensão de ponta de mesma área molhada e com uma de mesmo momento fletor na raiz (Jones, NACA TN 2249; Kroo
//! 2001). Nada aloca: a matriz fica no `Workspace` de quem chama.
const std = @import("std");
const linalg = @import("../math/linalg.zig");

/// o maior número de painéis do traço (a caixa com h/b = 1 e 120 painéis no vão dá 480)
pub const max_panels = 512;

/// um ponto do plano de Trefftz: y (envergadura) e z (para cima)
pub const Point = [2]f64;

/// um trecho reto do traço da esteira
pub const Segment = struct { start: Point, end: Point };

/// os tipos de traço do estudo (`trace` de `tipdevices.py`)
pub const Kind = enum {
    plana,
    winglet,
    placa, // para cima e para baixo
    caixa,
    asa_c,

    /// o nome na tela
    pub fn title(kind: Kind) []const u8 {
        return switch (kind) {
            .plana => "sem dispositivo",
            .winglet => "winglet",
            .placa => "placa de ponta",
            .caixa => "asa em caixa",
            .asa_c => "asa em C",
        };
    }
};

/// a memória de uma solução: a matriz de influência e os painéis (2 MB; quem chama guarda)
pub const Workspace = struct {
    matrix: [max_panels][max_panels]f64 = undefined,
    pivots: [max_panels]usize = undefined,
    gamma: [max_panels]f64 = undefined,
    start: [max_panels]Point = undefined,
    end: [max_panels]Point = undefined,
};

/// o carregamento ótimo (ρ = V = 1, L = 1): o fator e, o arrasto induzido e o momento fletor na raiz da semiasa direita
pub const Loading = struct { efficiency: f64, drag: f64, root_moment: f64 };

pub const Error = error{ TooManyPanels, Singular };

/// arredonda como o `round` do Python (o meio vai para o par), para a malha sair igual
fn roundHalfEven(value: f64) f64 {
    const floor = @floor(value);
    const fraction = value - floor;
    if (fraction > 0.5) return floor + 1;
    if (fraction < 0.5) return floor;
    return if (@mod(floor, 2) == 0) floor else floor + 1;
}

/// os painéis de um trecho, todos com o comprimento perto de `spacing` (com espaçamento cosseno o painel minúsculo
/// junto às junções não converge; `_seg` de `tipdevices.py`)
fn addSegment(work: *Workspace, count: *usize, segment: Segment, spacing: f64) Error!void {
    const dy = segment.end[0] - segment.start[0];
    const dz = segment.end[1] - segment.start[1];
    const panels: usize = @intFromFloat(@max(2, roundHalfEven(std.math.hypot(dy, dz) / spacing)));
    if (count.* + panels > max_panels) return error.TooManyPanels;
    const total: f64 = @floatFromInt(panels);
    for (0..panels) |k| {
        const t0 = @as(f64, @floatFromInt(k)) / total;
        const t1 = @as(f64, @floatFromInt(k + 1)) / total;
        const start: Point = .{ segment.start[0] + t0 * dy, segment.start[1] + t0 * dz };
        const end: Point = .{ segment.start[0] + t1 * dy, segment.start[1] + t1 * dz };
        if (std.math.hypot(end[0] - start[0], end[1] - start[1]) <= 1e-12) continue;
        work.start[count.*] = start;
        work.end[count.*] = end;
        count.* += 1;
    }
}

/// os trechos do traço de um tipo de dispositivo com envergadura `span` e altura relativa `height` (h/b); `cap`: o
/// comprimento da aba da asa em C, em fração do vão (`trace` de `tipdevices.py`)
pub fn trace(kind: Kind, height: f64, cap: f64, span: f64, buffer: *[7]Segment) []const Segment {
    const half = span / 2;
    const tall = height * span;
    var count: usize = 0;
    const add = struct {
        fn segment(list: *[7]Segment, used: *usize, start: Point, end: Point) void {
            list[used.*] = .{ .start = start, .end = end };
            used.* += 1;
        }
    }.segment;
    add(buffer, &count, .{ -half, 0 }, .{ half, 0 });
    switch (kind) {
        .plana => {},
        .winglet, .asa_c => {
            add(buffer, &count, .{ half, 0 }, .{ half, tall });
            add(buffer, &count, .{ -half, tall }, .{ -half, 0 });
            if (kind == .asa_c) {
                add(buffer, &count, .{ half, tall }, .{ half - cap * span, tall });
                add(buffer, &count, .{ -half + cap * span, tall }, .{ -half, tall });
            }
        },
        .placa => for ([2]f64{ half, -half }) |y| {
            add(buffer, &count, .{ y, 0 }, .{ y, tall / 2 });
            add(buffer, &count, .{ y, 0 }, .{ y, -tall / 2 });
        },
        .caixa => {
            add(buffer, &count, .{ half, 0 }, .{ half, tall });
            add(buffer, &count, .{ half, tall }, .{ -half, tall });
            add(buffer, &count, .{ -half, tall }, .{ -half, 0 });
        },
    }
    return buffer[0..count];
}

/// a circulação ótima e o fator e de um traço com `panels` painéis no vão de referência `span`
/// (`optimal_loading` de `tipdevices.py`)
pub fn optimal(work: *Workspace, segments: []const Segment, panels: usize, span: f64) Error!Loading {
    const spacing = span / @as(f64, @floatFromInt(panels));
    var count: usize = 0;
    for (segments) |segment| try addSegment(work, &count, segment, spacing);
    // M[i][j] = ½ ℓ_i w_n,i(Γ_j = 1): o painel j é um vórtice +1 no começo e −1 no fim
    for (0..count) |i| {
        const start = work.start[i];
        const end = work.end[i];
        const length = std.math.hypot(end[0] - start[0], end[1] - start[1]);
        const tangent: Point = .{ (end[0] - start[0]) / length, (end[1] - start[1]) / length };
        const normal: Point = .{ -tangent[1], tangent[0] };
        const middle: Point = .{ 0.5 * (start[0] + end[0]), 0.5 * (start[1] + end[1]) };
        for (0..count) |j| {
            const first = induced(middle, work.start[j]);
            const last = induced(middle, work.end[j]);
            const normal_speed = (first[0] - last[0]) * normal[0] + (first[1] - last[1]) * normal[1];
            work.matrix[i][j] = 0.5 * length * normal_speed;
        }
    }
    for (0..count) |i| for (i + 1..count) |j| {
        const mean = 0.5 * (work.matrix[i][j] + work.matrix[j][i]);
        work.matrix[i][j] = mean;
        work.matrix[j][i] = mean;
    };
    // M Γ = b (b = a projeção de cada painel no vão: a sustentação de Γ unitário), depois L = 1
    var lift: [max_panels]f64 = undefined;
    for (0..count) |i| lift[i] = work.end[i][0] - work.start[i][0];
    const factors = &work.matrix;
    if (!linalg.luFactor(max_panels, factors, count, &work.pivots)) return error.Singular;
    work.gamma = lift;
    linalg.luSolve(max_panels, factors, count, &work.pivots, &work.gamma);
    var total: f64 = 0;
    for (0..count) |i| total += lift[i] * work.gamma[i];
    for (work.gamma[0..count]) |*value| value.* /= total;
    // o arrasto Γᵀ M Γ com a matriz de novo (a fatoração a sobrescreveu)
    var drag: f64 = 0;
    var root_moment: f64 = 0;
    for (0..count) |i| {
        const start = work.start[i];
        const end = work.end[i];
        const length = std.math.hypot(end[0] - start[0], end[1] - start[1]);
        const tangent: Point = .{ (end[0] - start[0]) / length, (end[1] - start[1]) / length };
        const normal: Point = .{ -tangent[1], tangent[0] };
        const middle: Point = .{ 0.5 * (start[0] + end[0]), 0.5 * (start[1] + end[1]) };
        var row: f64 = 0;
        for (0..count) |j| {
            const first = induced(middle, work.start[j]);
            const last = induced(middle, work.end[j]);
            const own = 0.5 * length * ((first[0] - last[0]) * normal[0] + (first[1] - last[1]) * normal[1]);
            row += own * work.gamma[j];
        }
        drag += work.gamma[i] * row;
        // o momento fletor na raiz: a força Γ (−Δz, Δy) no ponto médio, só na semiasa direita
        if (middle[0] > 1e-12) root_moment += work.gamma[i] * ((end[0] - start[0]) * middle[0] + (end[1] - start[1]) * middle[1]);
    }
    // (M e a simetrizada dão o mesmo Γᵀ M Γ)
    return .{ .efficiency = 1.0 / (std.math.pi * 0.5 * span * span * drag), .drag = drag, .root_moment = root_moment };
}

/// a velocidade (v, w) em `point` de um vórtice unitário em `source` (sentido anti-horário)
fn induced(point: Point, source: Point) Point {
    const dy = point[0] - source[0];
    const dz = point[1] - source[1];
    const squared = @max(dy * dy + dz * dz, 1e-14);
    return .{ -dz / (2 * std.math.pi * squared), dy / (2 * std.math.pi * squared) };
}

/// o fator e de um tipo de dispositivo com extrapolação de Richardson (o erro da malha cai com 1/n):
/// e = 2 e(2n) − e(n) (`span_efficiency` de `tipdevices.py`)
pub fn efficiency(work: *Workspace, kind: Kind, height: f64, panels: usize, cap: f64) Error!f64 {
    var buffer: [7]Segment = undefined;
    const segments = trace(kind, height, cap, 1, &buffer);
    const coarse = (try optimal(work, segments, panels, 1)).efficiency;
    const fine = (try optimal(work, segments, 2 * panels, 1)).efficiency;
    return 2 * fine - coarse;
}

/// o fator de Oswald de asa reta de Raymer ("Aircraft Design: A Conceptual Approach", eq. 12.49):
/// e = 1,78 (1 − 0,045 AR^0,68) − 0,64
pub fn raymerOswald(aspect: f64) f64 {
    return 1.78 * (1 - 0.045 * std.math.pow(f64, aspect, 0.68)) - 0.64;
}

/// o caso do estudo: a asa, o C_L, a corda da ponta, a perda da asa real (e da planta) e o atrito do dispositivo
pub const Study = struct {
    span: f64,
    area: f64,
    lift: f64, // C_L
    tip_chord: f64,
    planform: f64 = 1, // e da asa real em relação ao carregamento ótimo
    friction: f64 = 0.006, // C_f
    cap: f64 = 0.25,
    panels: usize = 60,
};

/// o resultado de um h/b: o e ideal de cada tipo e a variação do arrasto total (%) de cada tipo e das extensões
pub const StudyPoint = struct {
    efficiency: std.EnumArray(Kind, f64),
    drag_change: std.EnumArray(Kind, f64),
    extension: f64, // extensão de ponta com a mesma área molhada de um par de winglets
    extension_same_moment: f64, // extensão com o mesmo momento fletor na raiz do winglet
};

/// um ponto do estudo (`device_study` de `tipdevices.py`): D/q = (C_L S)² / (π b² e e_planta) + C_f S_molhada,
/// relativo ao induzido da asa sem dispositivo
pub fn studyPoint(work: *Workspace, study: Study, height: f64) Error!StudyPoint {
    const lift_area = study.lift * study.area;
    const base = lift_area * lift_area / (std.math.pi * study.span * study.span * study.planform);
    var out: StudyPoint = .{ .efficiency = .initFill(1), .drag_change = .initFill(0), .extension = 0, .extension_same_moment = 0 };
    const tall = height * study.span;
    for ([_]Kind{ .winglet, .placa, .caixa, .asa_c }) |kind| {
        var factor: f64 = 1;
        var wet: f64 = 0;
        if (height > 1e-9) {
            factor = try efficiency(work, kind, height, study.panels, study.cap);
            wet = switch (kind) {
                .winglet, .placa => 2 * 2 * tall * study.tip_chord,
                .caixa => 2 * (2 * tall * study.tip_chord + study.span * study.tip_chord),
                .asa_c => 2 * 2 * (tall + study.cap * study.span) * study.tip_chord,
                .plana => 0,
            };
        }
        out.efficiency.set(kind, factor);
        out.drag_change.set(kind, 100 * (lift_area * lift_area / (std.math.pi * study.span * study.span * factor * study.planform) + study.friction * wet - base) / base);
    }
    // a extensão de ponta: a área molhada de um par de winglets (2 · 2 h c) vira Δb = 2 h
    const longer = study.span + 2 * height * study.span;
    out.extension = 100 * (lift_area * lift_area / (std.math.pi * longer * longer * study.planform) + study.friction * 2 * 2 * height * study.span * study.tip_chord - base) / base;
    // com o mesmo momento fletor na raiz do winglet: o M_raiz da elíptica cresce linearmente com o vão
    var buffer: [7]Segment = undefined;
    const flat_moment = (try optimal(work, trace(.plana, 0, study.cap, study.span, &buffer), study.panels, study.span)).root_moment;
    const moment = (try optimal(work, trace(if (height > 1e-9) .winglet else .plana, height, study.cap, study.span, &buffer), study.panels, study.span)).root_moment;
    const equal = study.span * moment / flat_moment;
    const wet = 2 * 2 * @max(equal - study.span, 0) / 2 * study.tip_chord;
    out.extension_same_moment = 100 * (lift_area * lift_area / (std.math.pi * equal * equal * study.planform) + study.friction * wet - base) / base;
    return out;
}

const testing = std.testing;

test "Trefftz: e da caixa, do winglet, da asa em C e da placa batem com o Python" {
    const work = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(work);
    // `span_efficiency` de `tipdevices.py` com n = 60 (a caixa com h/b = 0,2 dá e ≈ 1,46 em Kroo 2001)
    try testing.expectApproxEqAbs(1.4710017722588715, try efficiency(work, .caixa, 0.2, 60, 0.25), 1e-9);
    try testing.expectApproxEqAbs(1.218701315466227, try efficiency(work, .winglet, 0.1, 60, 0.25), 1e-9);
    try testing.expectApproxEqAbs(1.4697535938023976, try efficiency(work, .asa_c, 0.2, 60, 0.25), 1e-9);
    try testing.expectApproxEqAbs(1.289695553724743, try efficiency(work, .placa, 0.15, 60, 0.25), 1e-9);
    var buffer: [7]Segment = undefined;
    try testing.expectApproxEqAbs(0.1069765293740563, (try optimal(work, trace(.plana, 0, 0.25, 1, &buffer), 60, 1)).root_moment, 1e-9);
}

test "Trefftz: o estudo dos dispositivos bate com o Python" {
    const work = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(work);
    const study: Study = .{ .span = 2.5, .area = 1.0, .lift = 0.88, .tip_chord = 0.35, .planform = 0.906 };
    // `device_study(2.5, 1.0, 0.88, 0.35, e_planform=0.906, hb=linspace(0, 0.25, 11))`, h/b = 0,125 e 0,25
    const middle = try studyPoint(work, study, 0.125);
    try testing.expectApproxEqAbs(1.2691679961112121, middle.efficiency.get(.winglet), 1e-9);
    try testing.expectApproxEqAbs(5.923672339721169, middle.drag_change.get(.caixa), 1e-7);
    try testing.expectApproxEqAbs(-15.017812353877819, middle.extension_same_moment, 1e-7);
    const last = try studyPoint(work, study, 0.25);
    try testing.expectApproxEqAbs(1.513107989321782, last.efficiency.get(.winglet), 1e-9);
    try testing.expectApproxEqAbs(0.06377967101268077, last.drag_change.get(.caixa), 1e-7);
    try testing.expectApproxEqAbs(-26.414630735753818, last.extension_same_moment, 1e-7);
}
