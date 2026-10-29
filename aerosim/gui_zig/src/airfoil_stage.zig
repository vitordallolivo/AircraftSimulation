//! A etapa Perfis: os perfis candidatos, a polar 2D de cada um e os números que a asa vai usar, como a página
//! Perfis da GUI em Python (`aerosim/design/airfoils.py`, `aerosim/design/results.py: airfoil_stage`).
//!
//! Os candidatos vêm do avião aberto (os perfis das superfícies), da biblioteca `data/airfoils` (os `.dat` que
//! não são NACA), de um código NACA de 4 dígitos ou de uma polar exportada pelo XFLR5/XFOIL. A polar sai do
//! modelo do núcleo (`physics/section.zig`) ou, com o arquivo, da polar medida lida nos mesmos ângulos. A conta
//! fica no núcleo; aqui só se junta o que entra e se lê o arquivo.
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const core = @import("aerosim");

const model = aircraft_model.aircraft;
const airfoil = aircraft_model.airfoil;
const section = core.section;

pub const max_candidates = 16;
/// os ângulos da etapa: de −16° a 20°, de meio em meio grau (o `ALPHAS` da GUI)
pub const alpha_count = 73;

/// de onde vem a polar: o modelo do simulador (reta e estol) ou a polar medida de um arquivo do XFLR5/XFOIL
pub const Source = enum { modelo, arquivo };
/// os métodos marcados de um candidato (pode ser mais de um: cada um vira uma curva)
pub const Sources = std.EnumSet(Source);

/// um perfil candidato
pub const Candidate = struct {
    name: []const u8,
    origin: []const u8, // de onde veio o contorno: "naca", "dat", "parâmetros" (o `kind` da GUI)
    numbers: section.Airfoil,
    outline: []const [2]f64 = &.{}, // vazio: só parâmetros (ou só a polar)
    source: Source = .modelo, // o que segue para a asa
    methods: Sources = Sources.initOne(.modelo), // o que entra nos gráficos
    measured: ?*const section.Polar = null, // a polar do arquivo, em ordem de α
    measured_reynolds: f64 = std.math.nan(f64),
};

/// a polar e os números de um candidato
pub const Outcome = struct {
    polar: section.Polar = .{},
    ld: [section.max_points]f64 = undefined,
    metrics: ?section.Metrics = null,
};

/// os ângulos da etapa
pub fn alphas() [alpha_count]f64 {
    var out: [alpha_count]f64 = undefined;
    for (&out, 0..) |*alpha, i| alpha.* = -16 + 0.5 * @as(f64, @floatFromInt(i));
    return out;
}

/// a polar e os números de `candidate` pela fonte que segue para a asa
pub fn evaluate(candidate: *const Candidate, out: *Outcome) void {
    evaluateWith(candidate, candidate.source, out);
}

/// os métodos marcados; a asa usa a polar do arquivo se ela estiver marcada (e existir), senão o modelo
pub fn setMethods(candidate: *Candidate, methods: Sources) void {
    var chosen = methods;
    if (candidate.measured == null) chosen.remove(.arquivo);
    if (chosen.count() == 0) chosen.insert(.modelo);
    candidate.methods = chosen;
    candidate.source = if (chosen.contains(.arquivo)) .arquivo else .modelo;
}

/// a polar e os números de `candidate` pela fonte `method`
pub fn evaluateWith(candidate: *const Candidate, method: Source, out: *Outcome) void {
    const angles = alphas();
    if (method == .arquivo and candidate.measured != null) {
        section.interpolate(candidate.measured.?, &angles, &out.polar);
    } else {
        section.modelPolar(candidate.numbers, &angles, &out.polar);
    }
    for (0..out.polar.count) |i| out.ld[i] = if (out.polar.cd[i] > 0) out.polar.cl[i] / out.polar.cd[i] else std.math.nan(f64);
    out.metrics = section.metrics(&out.polar);
}

/// um candidato a partir do perfil de uma superfície (os números que faltam saem da linha média do contorno, como
/// `Airfoil.zero_lift_angle` e `moment_ac`)
pub fn fromAircraft(allocator: std.mem.Allocator, af: model.Airfoil, origin: []const u8) !Candidate {
    const outline = try contour(allocator, af.name, af.coords, af.inverted);
    var thin: [2]f64 = .{ 0, 0 };
    if (af.alpha0 == null or af.cm_ac == null) thin = airfoil.thinAirfoil(outline);
    return .{
        .name = af.name,
        .origin = origin,
        .numbers = .{ .cl_alpha = af.cl_alpha, .alpha0 = af.alpha0 orelse thin[0], .cl_max = af.cl_max, .cd0 = af.cd0, .cm_ac = af.cm_ac orelse thin[1] },
        .outline = outline,
    };
}

/// o contorno completo: o do arquivo ou o NACA pelo nome; invertido, o espelho em y na mesma ordem de percurso
fn contour(allocator: std.mem.Allocator, name: []const u8, coords: []const [2]f64, inverted: bool) ![]const [2]f64 {
    const profile = try allocator.create(airfoil.Profile);
    try airfoil.full(name, coords, profile);
    if (inverted) airfoil.invert(profile);
    return try allocator.dupe([2]f64, profile.slice());
}

/// os números padrão de um perfil novo (os do `Airfoil` da GUI em Python)
pub const default_numbers = struct {
    pub const cl_alpha = 5.9;
    pub const cl_max = 1.4;
    pub const cd0 = 0.012;
};

/// um candidato de um contorno (`.dat` ou NACA), com os números padrão e α_L0 e c_m da linha média
pub fn fromOutline(allocator: std.mem.Allocator, name: []const u8, coords: []const [2]f64, origin: []const u8) !Candidate {
    const outline = try contour(allocator, name, coords, false);
    const thin = airfoil.thinAirfoil(outline);
    return .{
        .name = try allocator.dupe(u8, name),
        .origin = origin,
        .numbers = .{ .cl_alpha = default_numbers.cl_alpha, .alpha0 = thin[0], .cl_max = default_numbers.cl_max, .cd0 = default_numbers.cd0, .cm_ac = thin[1] },
        .outline = outline,
    };
}

/// os perfis das superfícies do avião, sem repetir nome
pub fn aircraftCandidates(allocator: std.mem.Allocator, ac: *const model.Aircraft, out: []Candidate) !usize {
    var count: usize = 0;
    for (ac.surfaces) |surface| {
        if (count == out.len) break;
        var repeated = false;
        for (out[0..count]) |c| repeated = repeated or std.mem.eql(u8, c.name, surface.airfoil.name);
        if (repeated) continue;
        out[count] = try fromAircraft(allocator, surface.airfoil, surface.name);
        count += 1;
    }
    return count;
}

/// a maior flecha da linha média (fração da corda): a média entre extradorso e intradorso no mesmo x, em 200
/// pontos de espaçamento cosseno, como `camber_line` da GUI
pub fn maxCamber(outline: []const [2]f64) f64 {
    if (outline.len < 3) return 0;
    var leading: usize = 0;
    var x_low = outline[0][0];
    var x_high = outline[0][0];
    for (outline, 0..) |point, k| {
        if (point[0] < outline[leading][0]) leading = k;
        x_low = @min(x_low, point[0]);
        x_high = @max(x_high, point[0]);
    }
    if (!(x_high - x_low > 1e-9)) return 0;
    const upper = outline[0 .. leading + 1];
    const lower = outline[leading..];
    var largest: f64 = 0;
    for (0..200) |i| {
        const fraction = 0.5 * (1 - @cos(std.math.pi * @as(f64, @floatFromInt(i)) / 199.0));
        const x = x_low + (x_high - x_low) * fraction;
        largest = @max(largest, @abs(0.5 * (heightAt(upper, x) + heightAt(lower, x)) / (x_high - x_low)));
    }
    return largest;
}

/// y de uma metade do contorno em x (interpolado, saturado nas pontas; a metade pode vir em qualquer sentido)
fn heightAt(half: []const [2]f64, x: f64) f64 {
    var low_index: usize = 0;
    var high_index: usize = 0;
    for (half, 0..) |point, k| {
        if (point[0] < half[low_index][0]) low_index = k;
        if (point[0] > half[high_index][0]) high_index = k;
    }
    if (x <= half[low_index][0]) return half[low_index][1];
    if (x >= half[high_index][0]) return half[high_index][1];
    // o par vizinho que cerca x mais de perto (a metade é monótona em x)
    var best_left: ?usize = null;
    var best_right: ?usize = null;
    for (half, 0..) |point, k| {
        if (point[0] <= x and (best_left == null or point[0] > half[best_left.?][0])) best_left = k;
        if (point[0] >= x and (best_right == null or point[0] < half[best_right.?][0])) best_right = k;
    }
    const left = half[best_left.?];
    const right = half[best_right.?];
    if (right[0] - left[0] <= 0) return left[1];
    return left[1] + (x - left[0]) / (right[0] - left[0]) * (right[1] - left[1]);
}

/// o perfil de `candidate` pronto para a asa: os números ajustados na polar dele (a fonte escolhida) e o ramo do
/// c_d; simétrico (flecha < 0,3 %): α_L0 = c_m = 0
pub fn wingSection(candidate: *const Candidate) core.wing_line.SectionAirfoil {
    var outcome: Outcome = .{};
    evaluate(candidate, &outcome);
    const symmetric = candidate.outline.len > 0 and maxCamber(candidate.outline) < 0.003;
    return .{ .numbers = section.fitted(candidate.numbers, outcome.metrics, symmetric), .drag = section.dragBranch(&outcome.polar) };
}

/// é um NACA de 4 dígitos pelo nome ("naca" e quatro algarismos)?
pub fn isNaca4(name: []const u8) bool {
    var digits: usize = 0;
    for (name) |ch| {
        if (ch >= '0' and ch <= '9') digits += 1;
    }
    return digits == 4 and std.ascii.indexOfIgnoreCase(name, "naca") != null;
}

/// a polar exportada pelo XFLR5/XFOIL (texto) ou CSV: a tabela "alpha CL CD ... Cm" e o Re do cabeçalho; igual a
/// `read_polar_file` de `aerosim/aero/sections.py`
pub fn readPolarText(text: []const u8, out: *section.Polar) !f64 {
    var reynolds = std.math.nan(f64);
    var header: [16][]const u8 = undefined;
    var header_count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    out.count = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.math.isFinite(reynolds)) reynolds = headerReynolds(line);
        var tokens: [16][]const u8 = undefined;
        var token_count: usize = 0;
        var split = std.mem.tokenizeAny(u8, line, ", \t;");
        while (split.next()) |token| {
            if (token_count == tokens.len) break;
            tokens[token_count] = token;
            token_count += 1;
        }
        if (header_count == 0) {
            if (column(tokens[0..token_count], "alpha") != null and column(tokens[0..token_count], "cl") != null) {
                header_count = token_count;
                header = tokens;
            }
            continue;
        }
        var values: [16]f64 = undefined;
        var numeric = token_count >= 3;
        for (tokens[0..token_count], 0..) |token, k| values[k] = std.fmt.parseFloat(f64, token) catch blk: {
            numeric = false;
            break :blk 0;
        };
        if (!numeric or out.count == section.max_points) continue;
        const pick = struct {
            fn at(names: []const []const u8, row: []const f64, name: []const u8) f64 {
                const k = column(names, name) orelse return std.math.nan(f64);
                return if (k < row.len) row[k] else std.math.nan(f64);
            }
        };
        const names = header[0..header_count];
        const row = values[0..token_count];
        out.alpha[out.count] = pick.at(names, row, "alpha");
        out.cl[out.count] = pick.at(names, row, "cl");
        out.cd[out.count] = pick.at(names, row, "cd");
        const moment = pick.at(names, row, "cm");
        out.cm[out.count] = if (std.math.isFinite(moment)) moment else 0;
        out.count += 1;
    }
    if (header_count == 0 or out.count == 0) return error.NoTable;
    // em ordem de α
    for (1..out.count) |i| {
        var k = i;
        while (k > 0 and out.alpha[k - 1] > out.alpha[k]) : (k -= 1) {
            std.mem.swap(f64, &out.alpha[k - 1], &out.alpha[k]);
            std.mem.swap(f64, &out.cl[k - 1], &out.cl[k]);
            std.mem.swap(f64, &out.cd[k - 1], &out.cd[k]);
            std.mem.swap(f64, &out.cm[k - 1], &out.cm[k]);
        }
    }
    return reynolds;
}

/// a coluna `name` (sem diferença de maiúsculas) no cabeçalho
fn column(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, k| if (std.ascii.eqlIgnoreCase(candidate, name)) return k;
    return null;
}

/// o "Re = 0.200 e 6" (ou "Re = 200000") de uma linha do cabeçalho; NaN se não houver
fn headerReynolds(line: []const u8) f64 {
    const at = std.mem.indexOf(u8, line, "Re") orelse return std.math.nan(f64);
    var rest = std.mem.trimStart(u8, line[at + 2 ..], " ");
    if (rest.len == 0 or rest[0] != '=') return std.math.nan(f64);
    rest = std.mem.trimStart(u8, rest[1..], " ");
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.')) end += 1;
    const mantissa = std.fmt.parseFloat(f64, rest[0..end]) catch return std.math.nan(f64);
    var tail = std.mem.trimStart(u8, rest[end..], " ");
    if (tail.len > 0 and (tail[0] == 'e' or tail[0] == 'E')) {
        tail = std.mem.trimStart(u8, tail[1..], " ");
        var stop: usize = 0;
        while (stop < tail.len and (std.ascii.isDigit(tail[stop]) or tail[stop] == '+' or tail[stop] == '-')) stop += 1;
        const exponent = std.fmt.parseInt(i32, tail[0..stop], 10) catch return mantissa;
        return mantissa * std.math.pow(f64, 10, @floatFromInt(exponent));
    }
    return mantissa;
}

test "candidatos do avião de exemplo e a polar do XFLR5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // NACA 2412 com os números padrão: α_L0 e c_m da linha média, como `Airfoil("NACA 2412")` em Python
    const naca = try fromOutline(allocator, "NACA 2412", &.{}, "NACA");
    try std.testing.expectApproxEqAbs(@as(f64, -2.114661), naca.numbers.alpha0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, -0.052817), naca.numbers.cm_ac, 1e-5);
    try std.testing.expect(isNaca4("naca 4412") and !isNaca4("s1223"));
    const symmetric = try fromOutline(allocator, "NACA 0012", &.{}, "NACA");
    try std.testing.expect(maxCamber(symmetric.outline) < 1e-9 and maxCamber(naca.outline) > 0.019);
    var outcome: Outcome = .{};
    evaluate(&naca, &outcome);
    try std.testing.expect(outcome.metrics != null);
    // uma polar no formato do XFLR5
    const text =
        \\ xflr5 v6.57
        \\ Calculated polar for: S1223
        \\ Mach =   0.000     Re =     0.300 e 6     Ncrit =   9.000
        \\  alpha     CL        CD       CDp       Cm    Top Xtr Bot Xtr
        \\ ------- -------- --------- --------- -------- ------- -------
        \\   2.000   1.4000   0.01500   0.01000  -0.2500  0.5000  1.0000
        \\   0.000   1.2000   0.01400   0.00900  -0.2600  0.5000  1.0000
    ;
    var polar: section.Polar = .{};
    const reynolds = try readPolarText(text, &polar);
    try std.testing.expectApproxEqAbs(@as(f64, 3e5), reynolds, 1e-6);
    try std.testing.expectEqual(@as(usize, 2), polar.count);
    try std.testing.expectEqual(@as(f64, 0), polar.alpha[0]);
    try std.testing.expectEqual(@as(f64, 0.015), polar.cd[1]);
    try std.testing.expectEqual(@as(f64, -0.26), polar.cm[0]);
}

test "perfis do avião de exemplo: os mesmos números da GUI em Python" {
    const assembly = @import("assembly.zig");
    const io = std.testing.io;
    const path = "../../data/aircraft/S1223_monomotor_EH_convencional_Joinville.json";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1 << 24)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    var diagnosis: model.Diag = .{};
    var opened = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer opened.deinit();
    try assembly.fillAirfoilFiles(opened.arena.allocator(), io, path, bytes, &opened.ac);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var candidates: [max_candidates]Candidate = undefined;
    const count = try aircraftCandidates(arena.allocator(), &opened.ac, &candidates);
    try std.testing.expectEqual(@as(usize, 2), count);
    // referência: afm.metrics(afm.polar(AirfoilEntry(surface.airfoil), 3e5, source="modelo"))
    const expected = [_][5]f64{
        .{ 2.2576, 9.0, 137.3073, 7.6269, -9.1092 }, // S1223
        .{ 0.9768, 10.0, 100.6351, 6.1712, -0.0066 }, // HT 14
    };
    for (candidates[0..count], expected) |*candidate, numbers| {
        var outcome: Outcome = .{};
        evaluate(candidate, &outcome);
        const found = outcome.metrics.?;
        try std.testing.expectApproxEqAbs(numbers[0], found.cl_max, 1e-4);
        try std.testing.expectEqual(numbers[1], found.alpha_stall);
        try std.testing.expectApproxEqAbs(numbers[2], found.ld_max, 1e-3);
        try std.testing.expectApproxEqAbs(numbers[3], found.cl_alpha, 1e-4);
        try std.testing.expectApproxEqAbs(numbers[4], found.alpha0, 1e-4);
    }
}
