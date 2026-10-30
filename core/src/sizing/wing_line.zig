//! A etapa Asa do dimensionamento: do perfil escolhido à asa trapezoidal, pela linha sustentadora de Prandtl
//! (série de Glauert, simétrica), como `aerosim/design/wing.py: analyze`.
//!
//!   Σ A_n sen(nθ) (sen θ + n μ) = μ (α + ε(y) − α_L0) sen θ,   μ = a1 c / (4 b)
//!   C_L = π AR A_1      C_Di = π AR Σ n A_n²      c_l(y) = (4 b / c) Σ A_n sen(nθ)
//!
//! (a solução geral de Glauert para a linha sustentadora de Prandtl: Anderson, Fundamentals of Aerodynamics, seção
//! 5.3; número da equação a conferir no PDF). Como o sistema é
//! linear em α, ele se resolve duas vezes (a parte em α e a parte da torção) e c_l(y) = α g(y) + h(y). O C_L,max
//! sai da seção crítica: o primeiro ponto da envergadura que chega ao c_l,max do perfil diz também onde o estol
//! começa. O arrasto de perfil integra o c_d da polar 2D no c_l local. Com perfil na ponta, do fim do trecho
//! retangular até a ponta os números do perfil (a1, α_L0, c_l,max, c_m e o c_d) são interpolados.
//!
//! A planta pode ser o trapézio (envergadura, área ou corda, afilamento, trecho retangular) ou a tabela de
//! partições da planilha (`Partition`: envergadura, corda, afilamento, perfil, recuo e torção de cada trecho, do
//! centro para a ponta), como `stations` de `aerosim/design/wing.py`. Cada seção leva o seu perfil, e entre seções
//! vizinhas os números do perfil são interpolados (`station_weights` da GUI).
const std = @import("std");
const linalg = @import("../math/linalg.zig");
const section = @import("../physics/section.zig");

/// estações da linha sustentadora (o `n` de `lifting_line`)
pub const stations = 24;
/// o máximo de ângulos na curva da asa
pub const max_alphas = 256;
const g0 = 9.80665;
const air_viscosity = 1.81e-5; // Pa s, o MU_AIR da GUI

/// o máximo de partições na tabela
pub const max_partitions = 8;
/// o máximo de seções da planta: duas por partição (o degrau de corda ganha uma) e a da raiz
pub const max_sections = 2 * max_partitions + 1;
/// na junção de partições com cordas diferentes, a troca acontece num trecho deste tamanho (m), o `JUNCTION` da GUI
const junction = 1e-4;

/// a asa trapezoidal como se decide no dimensionamento (o `WingParams` da GUI, planta "trapézio")
pub const Trapezoid = struct {
    span: f64 = 2.4, // m, de ponta a ponta
    area: f64 = 0.85, // m²
    root_chord: f64 = 0.35, // m (vale com `size_by_chord`)
    size_by_chord: bool = false, // falso: a corda sai da área
    taper: f64 = 0.6, // corda da ponta / corda da raiz
    rect_fraction: f64 = 0.4, // fração da semienvergadura com corda constante
    sweep: f64 = 0, // graus, da linha de 1/4 da corda no trecho trapezoidal
    twist: f64 = -1, // graus, na ponta
    alpha_cruise: f64 = 0, // graus, da fuselagem no cruzeiro
};

/// uma partição da tabela (do centro para a ponta), o `WingPartition` da GUI: quanto soma na envergadura total
/// (metade de cada lado), a corda no começo, o afilamento (corda no fim / no começo), o perfil no fim (índice na
/// lista de perfis de quem chama; 0 = o da raiz), o recuo do bordo de ataque ao longo dela e a torção no fim
pub const Partition = struct {
    span: f64 = 1, // m
    chord: f64 = 0.3, // m
    taper: f64 = 1,
    airfoil: usize = 0,
    offset: f64 = 0, // m
    twist: f64 = 0, // graus, em relação à raiz
};

/// o perfil de uma seção já ajustado na polar, e o ramo colado da polar para o c_d
pub const SectionAirfoil = struct {
    numbers: section.Airfoil,
    drag: section.DragBranch,
};

/// as condições de projeto (o `Requirements` da GUI) e a massa por área da asa (das regras)
pub const Conditions = struct {
    mass: f64 = 10, // kg
    airspeed: f64 = 15, // m/s, cruzeiro
    density: f64 = 1.225, // kg/m³
    wing_density: f64 = 1.1, // kg/m²
};

/// densidade da atmosfera padrão na altitude-densidade `altitude` (m): ρ0 (1 − 2,25577·10⁻⁵ h)^4,25588, a
/// `isa_density` da GUI
pub fn isaDensity(altitude: f64) f64 {
    const height = std.math.clamp(altitude, -2000, 11000);
    return 1.225 * std.math.pow(f64, 1.0 - 2.25577e-5 * height, 4.25588);
}

/// o número de Reynolds de uma corda nas condições de projeto
pub fn reynolds(conditions: Conditions, chord: f64) f64 {
    return conditions.density * conditions.airspeed * chord / air_viscosity;
}

/// uma seção da asa (da raiz para a ponta); `airfoil` é o índice do perfil dela na lista de quem chama
pub const Station = struct { y: f64, chord: f64, offset: f64, twist: f64, airfoil: usize = 0 };

/// onde y cai entre as seções: a de dentro, a de fora e quanto se andou de uma para a outra (0 a 1)
const Between = struct { inner: usize, outer: usize, fraction: f64 };

/// a planta: semienvergadura, cordas e as seções (trapézio: raiz, quebra se houver, ponta; tabela: as das partições)
pub const Planform = struct {
    semispan: f64,
    break_y: f64,
    root_chord: f64,
    tip_chord: f64,
    sections: [max_sections]Station = undefined,
    count: usize = 0,

    /// entre que seções y cai (antes da raiz: a raiz; depois da ponta: a ponta)
    fn between(planform: *const Planform, y: f64) Between {
        const list = planform.sections[0..planform.count];
        if (y <= list[0].y) return .{ .inner = 0, .outer = 0, .fraction = 0 };
        for (1..list.len) |k| {
            if (y <= list[k].y) {
                const span = list[k].y - list[k - 1].y;
                return .{ .inner = k - 1, .outer = k, .fraction = if (span > 0) (y - list[k - 1].y) / span else 1 };
            }
        }
        return .{ .inner = list.len - 1, .outer = list.len - 1, .fraction = 0 };
    }

    /// a grandeza `field` interpolada em y (entre seções vizinhas; fora delas, a da ponta)
    fn at(planform: *const Planform, y: f64, comptime field: []const u8) f64 {
        const place = planform.between(y);
        const inner = @field(planform.sections[place.inner], field);
        return inner + place.fraction * (@field(planform.sections[place.outer], field) - inner);
    }

    /// a corda em y (m)
    pub fn chordAt(planform: *const Planform, y: f64) f64 {
        return planform.at(y, "chord");
    }

    /// a área das duas semiasas (m²)
    pub fn area(planform: *const Planform) f64 {
        var half: f64 = 0;
        for (1..planform.count) |k| half += 0.5 * (planform.sections[k - 1].chord + planform.sections[k].chord) * (planform.sections[k].y - planform.sections[k - 1].y);
        return 2 * half;
    }

    /// a corda média aerodinâmica (m), pela integral de c² em 201 pontos como a GUI
    pub fn meanChord(planform: *const Planform) f64 {
        var half: f64 = 0;
        var square: f64 = 0;
        const step = planform.semispan / 200.0;
        var previous = planform.chordAt(0);
        for (1..201) |i| {
            const chord = planform.chordAt(step * @as(f64, @floatFromInt(i)));
            half += 0.5 * step * (previous + chord);
            square += 0.5 * step * (previous * previous + chord * chord);
            previous = chord;
        }
        return square / half;
    }

    /// o centro aerodinâmico (1/4 da CMA) atrás do bordo de ataque da raiz (m), pela mesma integral de `meanChord`
    /// (o `planform` da GUI: x_ac = x_le_mac − 0,25 CMA, lá com x para a frente)
    pub fn aeroCenter(planform: *const Planform) f64 {
        var half: f64 = 0;
        var leading: f64 = 0;
        const step = planform.semispan / 200.0;
        var previous_chord = planform.chordAt(0);
        var previous_offset = planform.at(0, "offset");
        for (1..201) |i| {
            const y = step * @as(f64, @floatFromInt(i));
            const chord = planform.chordAt(y);
            const offset = planform.at(y, "offset");
            half += 0.5 * step * (previous_chord + chord);
            leading += 0.5 * step * (previous_chord * previous_offset + chord * offset);
            previous_chord = chord;
            previous_offset = offset;
        }
        return leading / half + 0.25 * planform.meanChord();
    }

    /// o enflechamento da linha de 1/4 da corda no último trecho (rad)
    fn quarterChordSweep(planform: *const Planform) f64 {
        const tip = planform.sections[planform.count - 1];
        const inner = planform.sections[if (planform.count > 1) planform.count - 2 else 0];
        const dy = tip.y - inner.y;
        if (dy <= 0) return 0;
        return std.math.atan(((tip.offset + 0.25 * tip.chord) - (inner.offset + 0.25 * inner.chord)) / dy);
    }
};

/// a planta do trapézio (`chords` e `build_wing` da GUI); `with_tip`: a seção da ponta leva o perfil da ponta
pub fn planformOf(trapezoid: Trapezoid, with_tip: bool) Planform {
    const semispan = trapezoid.span / 2;
    const break_y = std.math.clamp(trapezoid.rect_fraction, 0, 1) * semispan;
    const ratio = if (break_y >= semispan) 1.0 else trapezoid.taper;
    const root = if (trapezoid.size_by_chord) trapezoid.root_chord else trapezoid.area / (2 * (break_y + 0.5 * (1 + ratio) * (semispan - break_y)));
    const tip = root * ratio;
    var out: Planform = .{ .semispan = semispan, .break_y = break_y, .root_chord = root, .tip_chord = tip };
    out.sections[0] = .{ .y = 0, .chord = root, .offset = 0, .twist = 0 };
    out.count = 1;
    if (1e-6 < break_y and break_y < semispan - 1e-6) {
        out.sections[1] = .{ .y = break_y, .chord = root, .offset = 0, .twist = trapezoid.twist * break_y / semispan };
        out.count = 2;
    }
    const tip_offset = (root - tip) / 4 + @tan(std.math.degreesToRadians(trapezoid.sweep)) * (semispan - break_y);
    out.sections[out.count] = .{ .y = semispan, .chord = tip, .offset = tip_offset, .twist = trapezoid.twist, .airfoil = @intFromBool(with_tip) };
    out.count += 1;
    return out;
}

/// a planta da tabela de partições (`stations` da GUI): as partições de envergadura zero ficam de fora; no degrau
/// de corda entre duas partições, a troca acontece num trecho curtinho. A raiz leva o perfil 0
pub fn planformOfPartitions(partitions: []const Partition) Planform {
    var out: Planform = .{ .semispan = 0, .break_y = 0, .root_chord = 0, .tip_chord = 0 };
    var y: f64 = 0;
    var offset: f64 = 0;
    var twist: f64 = 0;
    for (partitions) |partition| {
        if (partition.span <= 0 or out.count + 2 > max_sections) continue;
        if (out.count == 0) {
            out.sections[0] = .{ .y = y, .chord = partition.chord, .offset = offset, .twist = twist, .airfoil = 0 };
            out.count = 1;
        } else if (@abs(out.sections[out.count - 1].chord - partition.chord) > 1e-9) {
            const previous = out.sections[out.count - 1];
            out.sections[out.count] = .{ .y = y + @min(junction, 0.25 * partition.span / 2), .chord = partition.chord, .offset = offset, .twist = twist, .airfoil = previous.airfoil };
            out.count += 1;
        }
        y += partition.span / 2;
        offset += partition.offset;
        twist = partition.twist;
        out.sections[out.count] = .{ .y = y, .chord = partition.chord * partition.taper, .offset = offset, .twist = twist, .airfoil = partition.airfoil };
        out.count += 1;
    }
    if (out.count == 0) return planformOf(.{}, false);
    out.semispan = out.sections[out.count - 1].y;
    out.root_chord = out.sections[0].chord;
    out.tip_chord = out.sections[out.count - 1].chord;
    return out;
}

/// a envergadura total e a área da tabela: a soma das partições (`totals` da GUI)
pub fn totals(partitions: []const Partition) struct { span: f64, area: f64 } {
    var span: f64 = 0;
    var area: f64 = 0;
    for (partitions) |partition| {
        if (partition.span <= 0) continue;
        span += partition.span;
        area += partition.span * partition.chord * (1 + partition.taper) / 2;
    }
    return .{ .span = span, .area = area };
}

/// a tabela que reproduz o trapézio (o trecho reto e o afilado), ponto de partida para editar, como
/// `partitions_from_trapezoid` da GUI; `tip_airfoil` é o índice do perfil da ponta (0 = o da raiz). Devolve quantas
pub fn partitionsFromTrapezoid(trapezoid: Trapezoid, tip_airfoil: usize, out: *[max_partitions]Partition) usize {
    const planform = planformOf(trapezoid, false);
    const semispan = planform.semispan;
    const break_y = planform.break_y;
    const root = planform.root_chord;
    const tip = planform.tip_chord;
    const tip_offset = (root - tip) / 4 + @tan(std.math.degreesToRadians(trapezoid.sweep)) * (semispan - break_y);
    var count: usize = 0;
    if (break_y > 1e-6) {
        out[count] = .{ .span = round(2 * break_y, 4), .chord = round(root, 4), .taper = 1, .airfoil = 0, .offset = 0, .twist = round(trapezoid.twist * break_y / semispan, 3) };
        count += 1;
    }
    if (semispan - break_y > 1e-6) {
        out[count] = .{ .span = round(2 * (semispan - break_y), 4), .chord = round(root, 4), .taper = round(tip / root, 4), .airfoil = tip_airfoil, .offset = round(tip_offset, 4), .twist = trapezoid.twist };
        count += 1;
    }
    if (tip_airfoil != 0 and count == 1) { // só o trecho afilado: o perfil da raiz numa partição de largura ~0
        out[1] = out[0];
        out[0] = .{ .span = 2 * junction, .chord = round(root, 4), .taper = 1, .airfoil = 0, .offset = 0, .twist = 0 };
        count = 2;
    }
    return count;
}

/// arredonda em `digits` casas (o `round` do Python, para a tabela sair com os mesmos números)
fn round(value: f64, comptime digits: u32) f64 {
    const scale = comptime std.math.pow(f64, 10, @floatFromInt(digits));
    return @round(value * scale) / scale;
}

/// o que a etapa Asa mostra
pub const Result = struct {
    reynolds: f64 = 0, // na corda média
    mean_chord: f64 = 0,
    root_chord: f64 = 0,
    tip_chord: f64 = 0,
    area: f64 = 0,
    span: f64 = 0,
    aspect_ratio: f64 = 0,
    lift_slope: f64 = 0, // C_Lα (1/rad)
    lift_zero: f64 = 0, // C_L0
    alpha_zero: f64 = 0, // graus
    lift_max: f64 = 0,
    alpha_stall: f64 = 0, // graus
    stall_fraction: f64 = 0, // 2y/b onde o estol começa
    oswald: f64 = 0, // no cruzeiro
    ld_max: f64 = 0,
    lift_at_ld: f64 = 0,
    lift_cruise: f64 = 0,
    alpha_cruise: f64 = 0, // graus, da asa
    drag_cruise: f64 = 0,
    ld_cruise: f64 = 0,
    stall_speed: f64 = 0,
    incidence: f64 = 0, // graus
    wing_loading: f64 = 0, // kg/m²
    wing_mass: f64 = 0, // kg
    moment: f64 = 0, // C_m,ac
    aero_center: f64 = 0, // m, o centro aerodinâmico atrás do bordo de ataque da raiz
    reynolds_root: f64 = 0,
    reynolds_tip: f64 = 0,
    // curvas
    alpha_count: usize = 0,
    alpha: [max_alphas]f64 = undefined, // graus
    lift: [max_alphas]f64 = undefined,
    induced: [max_alphas]f64 = undefined,
    profile: [max_alphas]f64 = undefined,
    drag: [max_alphas]f64 = undefined,
    ld: [max_alphas]f64 = undefined,
    // ao longo da envergadura (da raiz para a ponta)
    span_fraction: [stations]f64 = undefined,
    cl_cruise: [stations]f64 = undefined,
    cl_stall: [stations]f64 = undefined,
    cl_max_local: [stations]f64 = undefined,
    chord: [stations]f64 = undefined,
};

/// a linha sustentadora: a parte em α e a da torção, c_l(y) = α g + h, e os números locais do perfil
const Line = struct {
    y: [stations]f64,
    chord: [stations]f64,
    slope_part: [stations]f64, // A_α
    twist_part: [stations]f64, // A_t
    lift_rate: [stations]f64, // g
    lift_base: [stations]f64, // h
    cl_max: [stations]f64,
    moment: [stations]f64,
    place: [stations]Between, // entre que seções cada estação cai (o perfil local mistura os das duas)
    aspect_ratio: f64,
    area: f64,
    span: f64,
};

fn odd(j: usize) f64 {
    return @floatFromInt(2 * j + 1);
}

/// a linha sustentadora de Glauert na planta `planform` (estações da ponta para a raiz)
fn liftingLine(planform: *const Planform, airfoils: []const *const SectionAirfoil) Line {
    var line: Line = undefined;
    const semispan = planform.semispan;
    line.span = 2 * semispan;
    line.area = planform.area();
    line.aspect_ratio = line.span * line.span / line.area;
    const sweep_cos = @cos(planform.quarterChordSweep());
    var matrix: [stations][stations]f64 = undefined;
    var rhs_slope: [stations]f64 = undefined;
    var rhs_twist: [stations]f64 = undefined;
    var theta: [stations]f64 = undefined;
    for (0..stations) |i| {
        theta[i] = @as(f64, @floatFromInt(i + 1)) * std.math.pi / (2 * @as(f64, stations));
        const y = semispan * @cos(theta[i]);
        // o perfil local: o das duas seções vizinhas, interpolado
        const place = planform.between(y);
        const inner = airfoils[planform.sections[place.inner].airfoil].numbers;
        const outer = airfoils[planform.sections[place.outer].airfoil].numbers;
        const weight = place.fraction;
        const slope = (inner.cl_alpha + weight * (outer.cl_alpha - inner.cl_alpha)) * sweep_cos;
        const zero_lift = std.math.degreesToRadians(inner.alpha0 + weight * (outer.alpha0 - inner.alpha0));
        line.y[i] = y;
        line.chord[i] = planform.chordAt(y);
        line.place[i] = place;
        line.cl_max[i] = inner.cl_max + weight * (outer.cl_max - inner.cl_max);
        line.moment[i] = inner.cm_ac + weight * (outer.cm_ac - inner.cm_ac);
        const twist = std.math.degreesToRadians(planform.at(y, "twist"));
        const mu = slope * line.chord[i] / (4 * line.span);
        for (0..stations) |j| matrix[i][j] = @sin(theta[i] * odd(j)) * (@sin(theta[i]) + odd(j) * mu);
        rhs_slope[i] = mu * @sin(theta[i]);
        rhs_twist[i] = mu * (twist - zero_lift) * @sin(theta[i]);
    }
    _ = linalg.solve(stations, matrix, stations, rhs_slope, &line.slope_part);
    _ = linalg.solve(stations, matrix, stations, rhs_twist, &line.twist_part);
    for (0..stations) |i| {
        var rate: f64 = 0;
        var base: f64 = 0;
        for (0..stations) |j| {
            rate += @sin(theta[i] * odd(j)) * line.slope_part[j];
            base += @sin(theta[i] * odd(j)) * line.twist_part[j];
        }
        line.lift_rate[i] = 4 * line.span / line.chord[i] * rate;
        line.lift_base[i] = 4 * line.span / line.chord[i] * base;
    }
    return line;
}

/// C_Di/(π AR) num ângulo: Σ n A_n²
fn inducedSum(line: *const Line, alpha: f64) f64 {
    var sum: f64 = 0;
    for (0..stations) |j| {
        const coefficient = alpha * line.slope_part[j] + line.twist_part[j];
        sum += odd(j) * coefficient * coefficient;
    }
    return sum;
}

/// C_Dp = (2/S) ∫ c c_d(c_l local) dy, da raiz à ponta (a ponta com o c_d da última estação)
fn profileDrag(planform: *const Planform, line: *const Line, alpha: f64, airfoils: []const *const SectionAirfoil) f64 {
    var integral: f64 = 0;
    var previous_y: f64 = 0;
    var previous_value: f64 = 0;
    var last_cd: f64 = 0;
    var i: usize = stations;
    var first = true;
    while (i > 0) {
        i -= 1;
        const cl = alpha * line.lift_rate[i] + line.lift_base[i];
        const place = line.place[i];
        const inner = planform.sections[place.inner].airfoil;
        const outer = planform.sections[place.outer].airfoil;
        var cd = airfoils[inner].drag.at(cl);
        if (outer != inner) cd += (airfoils[outer].drag.at(cl) - cd) * place.fraction;
        const value = line.chord[i] * cd;
        if (!first) integral += 0.5 * (line.y[i] - previous_y) * (value + previous_value);
        first = false;
        previous_y = line.y[i];
        previous_value = value;
        last_cd = cd;
    }
    const tip_value = planform.chordAt(planform.semispan) * last_cd;
    integral += 0.5 * (planform.semispan - previous_y) * (tip_value + previous_value);
    return 2 * integral / line.area;
}

/// tudo o que a etapa Asa mostra: curvas, estol (quanto e onde), polar, L/D, cruzeiro e massa
pub fn analyze(trapezoid: Trapezoid, root: *const SectionAirfoil, tip: ?*const SectionAirfoil, conditions: Conditions, out: *Result) void {
    const planform = planformOf(trapezoid, tip != null);
    const both = [2]*const SectionAirfoil{ root, tip orelse root };
    analyzePlanform(&planform, both[0..if (tip != null) 2 else 1], trapezoid.alpha_cruise, conditions, out);
}

/// a etapa Asa numa planta qualquer (trapézio ou tabela): `airfoils` são os perfis das seções (o 0 é o da raiz;
/// `Station.airfoil` aponta para eles) e `alpha_cruise` o ângulo da fuselagem no cruzeiro (graus)
pub fn analyzePlanform(planform: *const Planform, airfoils: []const *const SectionAirfoil, alpha_cruise_body: f64, conditions: Conditions, out: *Result) void {
    const line = liftingLine(planform, airfoils);
    const aspect = line.aspect_ratio;
    // a seção crítica: o menor α em que alguma estação chega ao c_l,max dela
    var critical: usize = 0;
    var stall = std.math.inf(f64);
    for (0..stations) |i| {
        const angle = if (line.lift_rate[i] > 0) (line.cl_max[i] - line.lift_base[i]) / line.lift_rate[i] else std.math.inf(f64);
        if (angle < stall) {
            stall = angle;
            critical = i;
        }
    }
    out.mean_chord = planform.meanChord();
    out.reynolds = reynolds(conditions, out.mean_chord);
    out.root_chord = planform.root_chord;
    out.tip_chord = planform.tip_chord;
    out.area = line.area;
    out.span = line.span;
    out.aspect_ratio = aspect;
    out.lift_slope = std.math.pi * aspect * line.slope_part[0];
    out.lift_zero = std.math.pi * aspect * line.twist_part[0];
    const alpha_zero = -out.lift_zero / out.lift_slope;
    out.alpha_zero = std.math.radiansToDegrees(alpha_zero);
    out.lift_max = std.math.pi * aspect * (stall * line.slope_part[0] + line.twist_part[0]);
    out.alpha_stall = std.math.radiansToDegrees(stall);
    out.stall_fraction = line.y[critical] / planform.semispan;
    // a curva: de α_L0 − 2° (para baixo, inteiro) até o estol, de 0,25° em 0,25° (np.arange), e o próprio estol
    const start = @floor(out.alpha_zero) - 2;
    const stop = out.alpha_stall + 1e-9;
    const steps: usize = @intFromFloat(@max(0, @ceil((stop - start) / 0.25)));
    out.alpha_count = 0;
    for (0..@min(steps, max_alphas - 1)) |k| {
        out.alpha[out.alpha_count] = start + 0.25 * @as(f64, @floatFromInt(k));
        out.alpha_count += 1;
    }
    if (out.alpha_count == 0 or out.alpha[out.alpha_count - 1] < out.alpha_stall - 1e-9) {
        out.alpha[out.alpha_count] = out.alpha_stall;
        out.alpha_count += 1;
    }
    var best: usize = 0;
    out.ld_max = -std.math.inf(f64);
    for (0..out.alpha_count) |k| {
        const angle = std.math.degreesToRadians(out.alpha[k]);
        out.lift[k] = std.math.pi * aspect * (angle * line.slope_part[0] + line.twist_part[0]);
        out.induced[k] = std.math.pi * aspect * inducedSum(&line, angle);
        out.profile[k] = profileDrag(planform, &line, angle, airfoils);
        out.drag[k] = out.induced[k] + out.profile[k];
        out.ld[k] = if (out.drag[k] > 0) out.lift[k] / out.drag[k] else std.math.nan(f64);
        if (out.ld[k] > out.ld_max) {
            out.ld_max = out.ld[k];
            best = k;
        }
    }
    out.lift_at_ld = out.lift[best];
    // cruzeiro: o C_L que sustenta a massa na velocidade de cruzeiro
    const dynamic_pressure = 0.5 * conditions.density * conditions.airspeed * conditions.airspeed;
    out.lift_cruise = conditions.mass * g0 / (dynamic_pressure * line.area);
    const alpha_cruise = (out.lift_cruise - out.lift_zero) / out.lift_slope;
    out.alpha_cruise = std.math.radiansToDegrees(alpha_cruise);
    const first_cruise = alpha_cruise * line.slope_part[0] + line.twist_part[0];
    const cruise_sum = inducedSum(&line, alpha_cruise);
    out.oswald = if (@abs(first_cruise) > 1e-12) first_cruise * first_cruise / cruise_sum else std.math.nan(f64);
    out.drag_cruise = std.math.pi * aspect * cruise_sum + profileDrag(planform, &line, alpha_cruise, airfoils);
    out.ld_cruise = if (out.drag_cruise > 0) out.lift_cruise / out.drag_cruise else std.math.nan(f64);
    out.stall_speed = if (out.lift_max > 0) @sqrt(2 * conditions.mass * g0 / (conditions.density * line.area * out.lift_max)) else std.math.nan(f64);
    out.incidence = out.alpha_cruise - alpha_cruise_body;
    out.wing_loading = conditions.mass / line.area;
    out.wing_mass = line.area * conditions.wing_density;
    out.reynolds_root = reynolds(conditions, planform.chordAt(0));
    out.reynolds_tip = reynolds(conditions, planform.chordAt(planform.semispan));
    // ao longo da envergadura, da raiz para a ponta
    for (0..stations) |k| {
        const i = stations - 1 - k;
        out.span_fraction[k] = line.y[i] / planform.semispan;
        out.cl_cruise[k] = alpha_cruise * line.lift_rate[i] + line.lift_base[i];
        out.cl_stall[k] = stall * line.lift_rate[i] + line.lift_base[i];
        out.cl_max_local[k] = line.cl_max[i];
        out.chord[k] = line.chord[i];
    }
    out.aero_center = planform.aeroCenter();
    // C_m,ac: um perfil só, o dele; mais de um, a média em c² ao longo da envergadura
    if (airfoils.len < 2) {
        out.moment = airfoils[0].numbers.cm_ac;
    } else {
        var weighted: f64 = 0;
        var total: f64 = 0;
        for (1..stations) |k| {
            const i = stations - 1 - k;
            const step = out.span_fraction[k] - out.span_fraction[k - 1];
            const a = line.chord[i + 1] * line.chord[i + 1];
            const b = line.chord[i] * line.chord[i];
            weighted += 0.5 * step * (line.moment[i + 1] * a + line.moment[i] * b);
            total += 0.5 * step * (a + b);
        }
        out.moment = weighted / total;
    }
}

/// o perfil ajustado na polar do modelo e o ramo do c_d, de um perfil com os números dados
pub fn modelSection(numbers: section.Airfoil, symmetric: bool) SectionAirfoil {
    var alphas: [73]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = -16 + 0.5 * @as(f64, @floatFromInt(i));
    var polar: section.Polar = .{};
    section.modelPolar(numbers, &alphas, &polar);
    return .{ .numbers = section.fitted(numbers, section.metrics(&polar), symmetric), .drag = section.dragBranch(&polar) };
}

test "asa trapezoidal: os números da etapa Asa da GUI em Python" {
    // referência: wing.analyze(WingCandidate(WingParams(), AirfoilEntry(Airfoil(), "modelo")), Requirements(),
    // DesignRules()); o NACA 2412 padrão tem α_L0 e c_m da linha média (−2,114661°, −0,052817)
    const root = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -2.114661308661674, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05281661064824909 }, false);
    const conditions: Conditions = .{ .density = isaDensity(600) };
    var result: Result = .{};
    analyze(.{}, &root, null, conditions, &result);
    const expected = [_][2]f64{
        .{ 347000.387654, result.reynolds },  .{ 4.556875, result.lift_slope },  .{ 0.133356, result.lift_zero },
        .{ -1.676747, result.alpha_zero },    .{ 1.297586, result.lift_max },    .{ 14.638423, result.alpha_stall },
        .{ 0.988337, result.oswald },         .{ 20.967098, result.ld_max },     .{ 0.511135, result.lift_at_ld },
        .{ 0.887156, result.lift_cruise },    .{ 9.477894, result.alpha_cruise }, .{ 0.049412, result.drag_cruise },
        .{ 17.95426, result.ld_cruise },      .{ 12.4029, result.stall_speed },  .{ 0.935, result.wing_mass },
        .{ 6.776471, result.aspect_ratio },   .{ 0.362216, result.mean_chord },  .{ -0.052817, result.moment },
        .{ 231333.267228, result.reynolds_tip },
    };
    for (expected) |pair| try std.testing.expectApproxEqRel(pair[0], pair[1], 2e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.stall_fraction, 1e-12);
    try std.testing.expectEqual(@as(usize, 76), result.alpha_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.011997), result.profile[0], 2e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.093638), result.drag[result.alpha_count - 1], 2e-6);
}

test "asa com perfil na ponta, enflechada e dimensionada pela corda: igual à GUI em Python" {
    // referência: WingParams(sweep=10, twist=-2, size_by="corda", chord=0.4), raiz NACA 2412 e ponta
    // from_dat("data/airfoils/s1223.dat") (α_L0 e c_m da linha média: −14,341063°, −0,394150), os dois "modelo"
    const root = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -2.114661308661674, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05281661064824909 }, false);
    const tip = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -14.341063304048808, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.39415016947412235 }, false);
    var result: Result = .{};
    analyze(.{ .sweep = 10, .twist = -2, .size_by_chord = true, .root_chord = 0.4 }, &root, &tip, .{ .density = isaDensity(600) }, &result);
    const expected = [_][2]f64{
        .{ 344877.561753, result.reynolds },  .{ 5.474257, result.lift_slope },  .{ 0.196327, result.lift_zero },
        .{ -2.054841, result.alpha_zero },    .{ 1.121016, result.lift_max },    .{ 9.67817, result.alpha_stall },
        .{ 0.793353, result.stall_fraction }, .{ 0.85064, result.oswald },       .{ 18.6105, result.ld_max },
        .{ 0.506845, result.lift_at_ld },     .{ 0.892617, result.lift_cruise }, .{ 7.287648, result.alpha_cruise },
        .{ 0.055879, result.drag_cruise },    .{ 15.974163, result.ld_cruise },  .{ 13.384983, result.stall_speed },
        .{ 0.92928, result.wing_mass },       .{ 6.818182, result.aspect_ratio }, .{ 0.360001, result.mean_chord },
        .{ -0.123373, result.moment },        .{ 229918.051946, result.reynolds_tip },
    };
    for (expected) |pair| try std.testing.expectApproxEqRel(pair[0], pair[1], 2e-5);
    try std.testing.expectEqual(@as(usize, 60), result.alpha_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.034208), result.profile[0], 2e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.080624), result.drag[result.alpha_count - 1], 2e-6);
}

test "asa pela tabela de partições, com degrau de corda e perfil na ponta: igual à GUI em Python" {
    // referência: WingParams(planform="tabela de seções", partitions=[WingPartition(0.8, 0.36, 1, "", 0, 0),
    // WingPartition(1.6, 0.32, 0.6, "S1223HiRes", 0.05, -2)]), raiz NACA 2412 e a outra seção o s1223.dat, "modelo"
    const root = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -2.114661308661674, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05281661064824909 }, false);
    const tip = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -14.341063304048808, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.39415016947412235 }, false);
    const partitions = [_]Partition{
        .{ .span = 0.8, .chord = 0.36, .taper = 1, .airfoil = 0, .offset = 0, .twist = 0 },
        .{ .span = 1.6, .chord = 0.32, .taper = 0.6, .airfoil = 1, .offset = 0.05, .twist = -2 },
    };
    const planform = planformOfPartitions(&partitions);
    // as seções: raiz, fim da primeira, o degrau de corda (0,1 mm depois) e a ponta
    try std.testing.expectEqual(@as(usize, 4), planform.count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4001), planform.sections[2].y, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.192), planform.tip_chord, 1e-12);
    const sum = totals(&partitions);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), sum.span, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6976), sum.area, 1e-12);
    const airfoils = [_]*const SectionAirfoil{ &root, &tip };
    var result: Result = .{};
    analyzePlanform(&planform, &airfoils, 0, .{ .density = isaDensity(600) }, &result);
    const expected = [_][2]f64{
        .{ 289340.675845, result.reynolds },  .{ 6.038904, result.lift_slope },  .{ 0.26576, result.lift_zero },
        .{ -2.521472, result.alpha_zero },    .{ 1.075278, result.lift_max },    .{ 7.680524, result.alpha_stall },
        .{ 0.793353, result.stall_fraction }, .{ 0.862934, result.oswald },      .{ 20.72242, result.ld_max },
        .{ 0.555607, result.lift_at_ld },     .{ 1.080941, result.lift_cruise }, .{ 7.734259, result.alpha_cruise },
        .{ 0.064553, result.drag_cruise },    .{ 16.745024, result.ld_cruise },  .{ 15.039451, result.stall_speed },
        .{ 0.767378, result.wing_mass },      .{ 8.256682, result.aspect_ratio }, .{ 0.302028, result.mean_chord },
        .{ -0.124743, result.moment },        .{ 183934.441557, result.reynolds_tip }, .{ 0.088962, result.aero_center },
    };
    for (expected) |pair| try std.testing.expectApproxEqRel(pair[0], pair[1], 2e-5);
    try std.testing.expectEqual(@as(usize, 52), result.alpha_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.036004), result.profile[0], 2e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.064001), result.drag[result.alpha_count - 1], 2e-6);
}

test "tabela a partir do trapézio e centro aerodinâmico do trapézio: iguais à GUI em Python" {
    var partitions: [max_partitions]Partition = undefined;
    const count = partitionsFromTrapezoid(.{ .sweep = 10, .twist = -2, .size_by_chord = true, .root_chord = 0.4 }, 1, &partitions);
    try std.testing.expectEqual(@as(usize, 2), count);
    const expected = [_][6]f64{ .{ 0.96, 0.4, 1, 0, 0, -0.8 }, .{ 1.44, 0.4, 0.6, 1, 0.167, -2 } };
    for (expected, partitions[0..count]) |row, partition| {
        const got = [6]f64{ partition.span, partition.chord, partition.taper, @floatFromInt(partition.airfoil), partition.offset, partition.twist };
        for (row, got) |want, value| try std.testing.expectApproxEqAbs(want, value, 1e-9);
    }
    // planform(build_wing(WingParams())): x_ac = −0,100616 (x para a frente)
    const planform = planformOf(.{}, false);
    try std.testing.expectApproxEqRel(@as(f64, 0.1006155303), planform.aeroCenter(), 1e-6);
}
