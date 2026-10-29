//! A asa da tela Analisar enquanto a tela ainda não lê o avião aberto: uma asa trapezoidal sem enflechamento
//! (linha de 1/4 de corda reta), cortada em faixas iguais, e as varreduras do núcleo (`loads/sweep.zig`) pelos
//! dois métodos: faixas independentes e linha sustentadora não linear. Provisório: quando o modelo universal for
//! para o Zig, as faixas saem dele e esta montagem some.
const std = @import("std");
const core = @import("aerosim");
const types = core.types;
const sweep = core.sweep;

pub const max_alphas = 128;
pub const max_panels = core.limits.max_surfaces;

/// o que o formulário dá
pub const Input = struct {
    span: f64 = 2.4, // envergadura (m)
    root_chord: f64 = 0.42, // corda na raiz (m)
    tip_chord: f64 = 0.3, // corda na ponta (m)
    lift_max: f64 = 1.6, // C_L máximo do perfil
    lift_slope: f64 = 2 * std.math.pi, // C_Lα do perfil (1/rad)
    airspeed: f64 = 12, // m/s
    density: f64 = 1.225, // kg/m³
    alpha_start: f64 = -4, // °
    alpha_end: f64 = 22, // °
    alpha_step: f64 = 1, // °
    alpha_load: f64 = 10, // α da distribuição ao longo da envergadura (°)
    panel_count: usize = 24, // faixas na envergadura inteira (par)
};

/// a curva de um método: C_L do conjunto em cada α e o resumo do núcleo
pub const Curve = struct {
    lift: [max_alphas]f64 = undefined,
    summary: sweep.Summary = undefined,
};

/// tudo o que a tela desenha
pub const Result = struct {
    alpha_count: usize = 0,
    alphas_deg: [max_alphas]f64 = undefined,
    strips: Curve = .{},
    lifting_line: Curve = .{},
    panel_count: usize = 0,
    panel_span: [max_panels]f64 = undefined, // y de cada faixa (m)
    panel_chord: [max_panels]f64 = undefined,
    section_cl_strips: [max_panels]f64 = undefined, // c_l no α da carga
    section_cl_lifting_line: [max_panels]f64 = undefined,
    load_strips: [max_panels]f64 = undefined, // L' = q c c_l (N/m) no α da carga
    load_lifting_line: [max_panels]f64 = undefined,
    area: f64 = 0,
    mean_chord: f64 = 0,
    aspect_ratio: f64 = 0,
    reynolds: f64 = 0,
};

pub const Error = error{ BadInput, BadIndex };

/// as faixas da asa trapezoidal, ordenadas da ponta esquerda à direita
pub fn buildParams(input: Input, params: *types.Params) Error!void {
    const count = input.panel_count;
    if (count < 2 or count > max_panels or count % 2 != 0) return error.BadInput;
    if (!(input.span > 0) or !(input.root_chord > 0) or !(input.tip_chord > 0)) return error.BadInput;
    params.* = .{};
    params.env.rho = input.density;
    params.n_surf = @intCast(count);
    const width = input.span / @as(f64, @floatFromInt(count));
    const area = 0.5 * (input.root_chord + input.tip_chord) * input.span;
    const aspect_ratio = input.span * input.span / area;
    const slope_3d = helmbold(input.lift_slope, aspect_ratio);
    for (0..count) |i| {
        const y_center = -0.5 * input.span + (@as(f64, @floatFromInt(i)) + 0.5) * width;
        const chord = chordAt(input, y_center);
        params.surf[i] = .{
            .r = .{ 0, y_center, 0 },
            .S = width * chord,
            .c = chord,
            .AR = aspect_ratio,
            .CLa = slope_3d, // o núcleo guarda o C_Lα 3D (como o tradutor em Python faz)
            .CLmax = input.lift_max,
            .CD0 = 0,
            .side = if (y_center > 0) 1 else -1,
            .qa = .{ 0, y_center - 0.5 * width, 0 },
            .qb = .{ 0, y_center + 0.5 * width, 0 },
        };
    }
    params.Sref = area;
    params.bref = input.span;
    core.aero.init(params);
}

/// C_Lα da asa a partir do 2D (Helmbold), a mesma relação que `core/src/loads/llt.zig` inverte:
/// C_Lα = a/(√(1+k²)+k), k = a/(π A)
pub fn helmbold(section_slope: f64, aspect_ratio: f64) f64 {
    const k = section_slope / (std.math.pi * aspect_ratio);
    return section_slope / (@sqrt(1 + k * k) + k);
}

/// corda na posição `y` da envergadura (variação linear da raiz à ponta)
pub fn chordAt(input: Input, y: f64) f64 {
    const fraction = @abs(y) / (0.5 * input.span);
    return input.root_chord + (input.tip_chord - input.root_chord) * fraction;
}

/// os ângulos da varredura, em graus
pub fn alphaList(input: Input, out: []f64) usize {
    if (!(input.alpha_step > 0) or !(input.alpha_end >= input.alpha_start)) return 0;
    var count: usize = 0;
    var alpha = input.alpha_start;
    while (alpha <= input.alpha_end + 1e-9 and count < out.len) : (count += 1) {
        out[count] = alpha;
        alpha = input.alpha_start + @as(f64, @floatFromInt(count + 1)) * input.alpha_step;
    }
    return count;
}

/// roda as varreduras do núcleo pelos dois métodos e a distribuição no α da carga
pub fn run(input: Input, result: *Result) Error!void {
    var params: types.Params = undefined;
    try buildParams(input, &params);
    result.* = .{};
    const count = input.panel_count;
    result.panel_count = count;
    result.alpha_count = alphaList(input, &result.alphas_deg);
    if (result.alpha_count == 0) return error.BadInput;
    var owners: [max_panels]i32 = undefined;
    @memset(owners[0..count], 0);
    var radians: [max_alphas]f64 = undefined;
    for (result.alphas_deg[0..result.alpha_count], 0..) |a, i| radians[i] = a * std.math.pi / 180;
    const dynamic_pressure = 0.5 * input.density * input.airspeed * input.airspeed;

    var area: [1]f64 = undefined;
    var chord: [1]f64 = undefined;
    var owner_lift: [max_alphas]f64 = undefined;
    var section_cl: [max_alphas * max_panels]f64 = undefined;
    inline for (.{ sweep.Method.strips, sweep.Method.lifting_line }) |method| {
        const curve = if (method == .strips) &result.strips else &result.lifting_line;
        try sweep.sweep(&params, input.airspeed, radians[0..result.alpha_count], owners[0..count], 1, method, .{
            .owner_lift = owner_lift[0..result.alpha_count],
            .owner_area = &area,
            .owner_chord = &chord,
            .section_cl = section_cl[0 .. result.alpha_count * count],
            .panel_span = result.panel_span[0..count],
        });
        var owner_cl: [max_alphas]f64 = undefined;
        curve.summary = try sweep.summarize(owner_lift[0..result.alpha_count], &area, dynamic_pressure, section_cl[0 .. result.alpha_count * count], owners[0..count], result.panel_span[0..count], curve.lift[0..result.alpha_count], owner_cl[0..result.alpha_count]);
        // distribuição no α da carga
        const load_alpha = [_]f64{input.alpha_load * std.math.pi / 180};
        var one_lift: [1]f64 = undefined;
        var one_cl: [max_panels]f64 = undefined;
        try sweep.sweep(&params, input.airspeed, &load_alpha, owners[0..count], 1, method, .{
            .owner_lift = &one_lift,
            .owner_area = &area,
            .owner_chord = &chord,
            .section_cl = one_cl[0..count],
            .panel_span = result.panel_span[0..count],
        });
        const cl_out = if (method == .strips) &result.section_cl_strips else &result.section_cl_lifting_line;
        const load_out = if (method == .strips) &result.load_strips else &result.load_lifting_line;
        for (0..count) |i| {
            cl_out[i] = one_cl[i];
            load_out[i] = dynamic_pressure * params.surf[i].c * one_cl[i]; // L' = q c c_l
        }
    }
    for (0..count) |i| result.panel_chord[i] = params.surf[i].c;
    result.area = area[0];
    result.mean_chord = chord[0];
    result.aspect_ratio = input.span * input.span / area[0];
    result.reynolds = sweep.reynolds(input.density, input.airspeed, chord[0], 0);
}

test "asa de exemplo: área do trapézio, C_L cresce com α e fica abaixo do perfil 2D nos dois métodos" {
    var result: Result = undefined;
    try run(.{}, &result);
    const input: Input = .{};
    try std.testing.expectApproxEqRel(0.5 * (input.root_chord + input.tip_chord) * input.span, result.area, 1e-9);
    try std.testing.expectEqual(@as(usize, 27), result.alpha_count);
    // no começo da faixa linear o C_L sobe com α nos dois métodos
    try std.testing.expect(result.strips.lift[6] > result.strips.lift[4]);
    try std.testing.expect(result.lifting_line.lift[6] > result.lifting_line.lift[4]);
    // asa finita: C_L/α abaixo do 2π do perfil nos dois métodos; nas faixas, o C_Lα de Helmbold (a 4°, índice 8)
    const four_degrees = 4 * std.math.pi / 180.0;
    try std.testing.expect(result.lifting_line.lift[8] / four_degrees < input.lift_slope);
    try std.testing.expectApproxEqRel(helmbold(input.lift_slope, result.aspect_ratio), result.strips.lift[8] / four_degrees, 0.02);
    try std.testing.expectApproxEqRel(result.lifting_line.lift[8], result.strips.lift[8], 0.15);
}

test "asa de exemplo: entrada inválida" {
    var result: Result = undefined;
    try std.testing.expectError(error.BadInput, run(.{ .panel_count = 7 }, &result));
    try std.testing.expectError(error.BadInput, run(.{ .span = 0 }, &result));
    try std.testing.expectError(error.BadInput, run(.{ .alpha_step = 0 }, &result));
}
