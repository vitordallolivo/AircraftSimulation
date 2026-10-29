//! Varredura das asas em α (subaba Asas da Aerodinâmica): só as superfícies escolhidas, sem trimar, sem fuselagem e
//! sem hélice, como num túnel de vento.
//!
//! `sweep` impõe cada α ao avião inteiro (β = 0, comandos em 0, longe do chão) e devolve a sustentação de cada "dono"
//! (uma superfície do avião, que o chamador indica painel a painel; −1 fica de fora), a área e a corda média
//! aerodinâmica de cada dono, e o c_l de cada painel. A carga sai das faixas da simulação (`aero.computeTrace`) ou da
//! linha sustentadora (`llt.apply`, linear ou não linear conforme `Params.llt_nonlinear`).
//!
//! `summarize` tira daí o C_L de cada dono e do conjunto (na soma das áreas), o C_L máximo e onde o estol começa: o
//! painel cujo c_l mais cai do α do pico para o α seguinte, e a posição dele na semienvergadura do seu dono.
//!
//! `reynolds` dá o número de Reynolds de uma corda, com a viscosidade do ar pela lei de Sutherland na temperatura da
//! atmosfera padrão.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const mods = @import("../modifiers/mod.zig");
const llt = @import("llt.zig");

const testing = std.testing;
const V3 = vec.V3;

/// de onde sai a carga em cada α
pub const Method = enum(i32) { strips = 0, lifting_line = 1 };

/// dono fora da faixa ou vetor de tamanho que não bate (o código numérico só existe na ABI)
pub const SweepError = error{BadIndex};

/// o que a varredura entrega, em vetores do chamador (α × dono e α × painel, α na linha)
pub const Output = struct {
    owner_lift: []f64, // sustentação de cada dono (N)
    owner_area: []f64, // área de cada dono (m²)
    owner_chord: []f64, // corda média aerodinâmica de cada dono (m): Σ S c / Σ S
    section_cl: []f64, // c_l de cada painel
    panel_span: []f64, // posição de cada painel ao longo da envergadura (y no corpo, m)
};

/// velocidade do ar no corpo para o ângulo de ataque `alpha` (rad), sem derrapagem
fn relativeWind(airspeed: f64, alpha: f64) V3 {
    const angle = fmath.sincos(alpha);
    return .{ airspeed * angle.c, 0, airspeed * angle.s };
}

/// varre `alphas` (rad) a `airspeed`: sustentação de cada dono, área e corda média de cada dono, c_l e posição de cada
/// painel. `owners[i]` é o dono do painel i (−1: fora da conta, ex.: deriva e placas de ponta)
pub fn sweep(params: *const types.Params, airspeed: f64, alphas: []const f64, owners: []const i32, owner_count: usize, method: Method, out: Output) SweepError!void {
    const panel_count: usize = @intCast(params.n_surf);
    if (owners.len < panel_count or panel_count > limits.max_surfaces) return error.BadIndex;
    if (out.owner_lift.len < alphas.len * owner_count or out.section_cl.len < alphas.len * panel_count) return error.BadIndex;
    if (out.owner_area.len < owner_count or out.owner_chord.len < owner_count or out.panel_span.len < panel_count) return error.BadIndex;
    for (owners[0..panel_count]) |owner| if (owner >= @as(i32, @intCast(owner_count))) return error.BadIndex;
    @memset(out.owner_area[0..owner_count], 0);
    @memset(out.owner_chord[0..owner_count], 0);
    for (params.surf[0..panel_count], owners[0..panel_count], 0..) |surface, owner, i| {
        out.panel_span[i] = surface.r[1];
        if (owner < 0) continue;
        const k: usize = @intCast(owner);
        out.owner_area[k] += surface.S;
        out.owner_chord[k] += surface.S * surface.c;
    }
    for (out.owner_chord[0..owner_count], out.owner_area[0..owner_count]) |*chord, area| {
        chord.* = if (area > 0) chord.* / area else 0;
    }
    var panels: [limits.max_surfaces]types.PanelState = undefined;
    var env = mods.Env.none;
    env.no_pair = method == .lifting_line; // a linha sustentadora já faz a interferência entre as asas
    for (alphas, 0..) |alpha, a| {
        const wind = relativeWind(airspeed, alpha);
        _ = aero.computeTrace(params, wind, vec.zero, vec.zero, 50.0, vec.zero, &env, panels[0..panel_count]);
        if (method == .lifting_line) _ = llt.apply(params, wind, vec.zero, panels[0..panel_count]);
        const lift_row = out.owner_lift[a * owner_count ..][0..owner_count];
        @memset(lift_row, 0);
        for (panels[0..panel_count], owners[0..panel_count], 0..) |panel, owner, i| {
            out.section_cl[a * panel_count + i] = panel.CL;
            if (owner >= 0) lift_row[@intCast(owner)] += panel.L;
        }
    }
}

/// o que `summarize` tira da varredura
pub const Summary = struct {
    peak: usize, // índice do α do C_L máximo do conjunto
    lift_max: f64, // C_L máximo do conjunto
    onset_panel: ?usize, // painel onde o estol começa (null: o pico é o último α, ou nada cai)
    onset_fraction: f64, // |y| do painel / maior |y| dos painéis do mesmo dono (0 raiz, 1 ponta)
};

/// C_L de cada dono (na área dele) e do conjunto (na soma das áreas) em cada α, o C_L máximo do conjunto e onde o
/// estol começa: o painel com dono cujo c_l mais cai do α do pico para o seguinte
pub fn summarize(owner_lift: []const f64, owner_area: []const f64, dynamic_pressure: f64, section_cl: []const f64, panel_owner: []const i32, panel_span: []const f64, total_cl: []f64, owner_cl: []f64) SweepError!Summary {
    const owner_count = owner_area.len;
    const alpha_count = total_cl.len;
    const panel_count = panel_owner.len;
    if (alpha_count == 0 or owner_lift.len < alpha_count * owner_count or owner_cl.len < alpha_count * owner_count) return error.BadIndex;
    if (section_cl.len < alpha_count * panel_count or panel_span.len < panel_count) return error.BadIndex;
    var total_area: f64 = 0;
    for (owner_area) |area| total_area += area;
    var peak: usize = 0;
    for (0..alpha_count) |a| {
        var lift: f64 = 0;
        for (0..owner_count) |k| {
            const value = owner_lift[a * owner_count + k];
            lift += value;
            owner_cl[a * owner_count + k] = if (owner_area[k] > 0 and dynamic_pressure > 0) value / (dynamic_pressure * owner_area[k]) else std.math.nan(f64);
        }
        total_cl[a] = if (total_area > 0 and dynamic_pressure > 0) lift / (dynamic_pressure * total_area) else std.math.nan(f64);
        if (total_cl[a] > total_cl[peak]) peak = a;
    }
    var summary = Summary{ .peak = peak, .lift_max = total_cl[peak], .onset_panel = null, .onset_fraction = 0 };
    if (peak + 1 >= alpha_count) return summary;
    var largest_drop: f64 = 0;
    for (panel_owner, 0..) |owner, i| {
        if (owner < 0) continue;
        const drop = section_cl[peak * panel_count + i] - section_cl[(peak + 1) * panel_count + i];
        if (drop > largest_drop) {
            largest_drop = drop;
            summary.onset_panel = i;
        }
    }
    if (summary.onset_panel) |panel| {
        var half_span: f64 = 0;
        for (panel_owner, panel_span) |owner, position| {
            if (owner == panel_owner[panel]) half_span = @max(half_span, @abs(position));
        }
        summary.onset_fraction = if (half_span > 0) @abs(panel_span[panel]) / half_span else 0;
    }
    return summary;
}

/// temperatura da atmosfera padrão na troposfera (K) na altitude `altitude` (m): T = T₀ − λ h, T₀ = 288,15 K,
/// λ = 0,0065 K/m (ICAO, Manual of the ICAO Standard Atmosphere, Doc 7488 — a conferir no PDF)
pub fn isaTemperature(altitude: f64) f64 {
    return 288.15 - 0.0065 * altitude;
}

/// viscosidade dinâmica do ar (Pa·s) pela lei de Sutherland: μ = μ₀ (T/T₀)^{3/2} (T₀ + S)/(T + S), μ₀ = 1,716e-5 Pa·s,
/// T₀ = 273,15 K, S = 110,4 K (White, Viscous Fluid Flow, 3ª ed., eq. 1-36 e tabela 1-2 — a conferir no PDF)
pub fn airViscosity(temperature: f64) f64 {
    const reference_viscosity = 1.716e-5;
    const reference_temperature = 273.15;
    const sutherland = 110.4;
    const ratio = temperature / reference_temperature;
    return reference_viscosity * ratio * @sqrt(ratio) * (reference_temperature + sutherland) / (temperature + sutherland);
}

/// número de Reynolds Re = ρ V c / μ de uma corda `chord` (m), com μ da atmosfera padrão na `altitude` (m)
pub fn reynolds(density: f64, airspeed: f64, chord: f64, altitude: f64) f64 {
    return density * airspeed * chord / airViscosity(isaTemperature(altitude));
}

// ---------------------------------------------------------------------------------------------------------- testes

/// asa reta e retangular em `panel_count` faixas (envergadura `wing_span`, corda `chord`), uma superfície só
fn rectangularWing(params: *types.Params, panel_count: usize, wing_span: f64, chord: f64, lift_max: f64) void {
    params.* = .{};
    params.n_surf = @intCast(panel_count);
    const width = wing_span / @as(f64, @floatFromInt(panel_count));
    for (0..panel_count) |i| {
        const y_center = -0.5 * wing_span + (@as(f64, @floatFromInt(i)) + 0.5) * width;
        params.surf[i] = .{ .r = .{ 0, y_center, 0 }, .S = width * chord, .c = chord, .AR = wing_span / chord, .CLa = 2 * fmath.pi,
            .CLmax = lift_max, .CD0 = 0, .side = if (y_center > 0) 1 else -1,
            .qa = .{ 0, y_center - 0.5 * width, 0 }, .qb = .{ 0, y_center + 0.5 * width, 0 } };
    }
    aero.init(params);
}

test "varredura: a sustentação do dono é a soma das faixas e a área e a corda saem das faixas" {
    var params: types.Params = undefined;
    rectangularWing(&params, 20, 2.0, 0.25, 1.3);
    var owners = [_]i32{0} ** 20;
    owners[0] = -1; // uma faixa fora da conta
    const alphas = [_]f64{ 0.02, 0.08 };
    var lift: [2]f64 = undefined;
    var area: [1]f64 = undefined;
    var chord: [1]f64 = undefined;
    var cl: [40]f64 = undefined;
    var span: [20]f64 = undefined;
    try sweep(&params, 12, &alphas, &owners, 1, .lifting_line, .{ .owner_lift = &lift, .owner_area = &area, .owner_chord = &chord, .section_cl = &cl, .panel_span = &span });
    try testing.expectApproxEqRel(2.0 * 0.25 * 19.0 / 20.0, area[0], 1e-12);
    try testing.expectApproxEqRel(0.25, chord[0], 1e-12);
    try testing.expect(lift[1] > lift[0] and lift[0] > 0);
    // a mesma conta painel a painel, pelas funções que a varredura chama
    var panels: [20]types.PanelState = undefined;
    var env = mods.Env.none;
    env.no_pair = true;
    const wind = relativeWind(12, alphas[1]);
    _ = aero.computeTrace(&params, wind, vec.zero, vec.zero, 50.0, vec.zero, &env, &panels);
    _ = llt.apply(&params, wind, vec.zero, &panels);
    var expected: f64 = 0;
    for (panels[1..]) |panel| expected += panel.L;
    try testing.expectApproxEqRel(expected, lift[1], 1e-12);
    try testing.expectEqual(panels[7].CL, cl[20 + 7]);
}

test "varredura: dono fora do intervalo e vetor curto viram erro" {
    var params: types.Params = undefined;
    rectangularWing(&params, 4, 1.0, 0.2, 1.2);
    const alphas = [_]f64{0.05};
    var lift: [1]f64 = undefined;
    var area: [1]f64 = undefined;
    var chord: [1]f64 = undefined;
    var cl: [4]f64 = undefined;
    var span: [4]f64 = undefined;
    const out = Output{ .owner_lift = &lift, .owner_area = &area, .owner_chord = &chord, .section_cl = &cl, .panel_span = &span };
    try testing.expectError(error.BadIndex, sweep(&params, 12, &alphas, &[_]i32{ 0, 0, 1, 0 }, 1, .strips, out));
    try testing.expectError(error.BadIndex, sweep(&params, 12, &alphas, &[_]i32{ 0, 0 }, 1, .strips, out));
    try testing.expectError(error.BadIndex, sweep(&params, 12, &alphas, &[_]i32{ 0, 0, 0, 0 }, 2, .strips, out));
}

test "resumo: C_L máximo e estol que começa na raiz da asa retangular (linha sustentadora não linear)" {
    // na asa retangular a carga é maior no meio, então o estol começa na raiz (Anderson, Fundamentals of
    // Aerodynamics, seção 5.3 — a conferir no PDF)
    var params: types.Params = undefined;
    rectangularWing(&params, 24, 2.0, 0.25, 1.3);
    params.llt_nonlinear = 1;
    params.llt_viscosity = 2;
    const owners = [_]i32{0} ** 24;
    var alphas: [16]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = std.math.degreesToRadians(@as(f64, @floatFromInt(2 * i)));
    var lift: [16]f64 = undefined;
    var area: [1]f64 = undefined;
    var chord: [1]f64 = undefined;
    var cl: [16 * 24]f64 = undefined;
    var span: [24]f64 = undefined;
    try sweep(&params, 12, &alphas, &owners, 1, .lifting_line, .{ .owner_lift = &lift, .owner_area = &area, .owner_chord = &chord, .section_cl = &cl, .panel_span = &span });
    var total: [16]f64 = undefined;
    var per_owner: [16]f64 = undefined;
    const dynamic_pressure = 0.5 * params.env.rho * 12 * 12;
    const summary = try summarize(&lift, &area, dynamic_pressure, &cl, &owners, &span, &total, &per_owner);
    try testing.expect(summary.peak > 2 and summary.peak < 15);
    try testing.expect(summary.lift_max < 1.3); // a asa finita não chega ao c_l,max do perfil
    try testing.expectEqual(total[summary.peak], summary.lift_max);
    try testing.expectApproxEqRel(total[4], per_owner[4], 1e-12); // um dono só: os dois C_L são o mesmo
    try testing.expect(summary.onset_panel != null);
    try testing.expect(summary.onset_fraction < 1.0 / 3.0);
}

test "resumo: pico no último α não tem início de estol" {
    const lift = [_]f64{ 1, 2, 3 };
    const area = [_]f64{1};
    const cl = [_]f64{ 0.1, 0.2, 0.3 };
    const owners = [_]i32{0};
    const span = [_]f64{0.5};
    var total: [3]f64 = undefined;
    var per_owner: [3]f64 = undefined;
    const summary = try summarize(&lift, &area, 10, &cl, &owners, &span, &total, &per_owner);
    try testing.expectEqual(@as(usize, 2), summary.peak);
    try testing.expect(summary.onset_panel == null);
    try testing.expectApproxEqRel(0.3, summary.lift_max, 1e-12);
}

test "Reynolds: viscosidade de Sutherland e Re de uma corda ao nível do mar" {
    // μ(288,15 K) = 1,789e-5 Pa·s na atmosfera padrão (ICAO Doc 7488, tabela — a conferir no PDF)
    try testing.expectApproxEqRel(1.789e-5, airViscosity(isaTemperature(0)), 2e-3);
    try testing.expectApproxEqRel(1.716e-5, airViscosity(273.15), 1e-12);
    // ρ V c / μ: 1,225 · 10 · 0,3 / 1,789e-5 ≈ 2,05e5
    try testing.expectApproxEqRel(2.054e5, reynolds(1.225, 10, 0.3, 0), 2e-3);
}
