//! A empenagem da etapa "Empenagem e comandos" (`aerosim/design/tail.py`): áreas por volume de cauda, estática
//! longitudinal clássica, faixa de CG, incidência da EH, rotação na decolagem, rolagem e direcional.
//!
//!     S_h = V_H S c̄ / l        S_v = V_V S b / l
//!     h_n = h_ac + η V_H (a_h / a) (1 − dε/dα),   dε/dα = 2 a / (π AR)
//!     C_m = C_m,ac + C_L (h − h_ac) − η V_H a_h (α_w − ε + i_h − α_0,h + τ δe)
//!
//! (Etkin e Reid, "Dynamics of Flight", seção 2.3; Nelson, "Flight Stability and Automatic Control", cap. 2;
//! Raymer, "Aircraft Design: A Conceptual Approach", cap. 4, 12 e 16; a conferir no PDF.)
//!
//! As posições são distâncias para trás do bordo de ataque da raiz da asa de referência (m); `h` é a fração da CMA
//! atrás do bordo de ataque dela.
const std = @import("std");
const wing_line = @import("wing_line.zig");

const pi = std.math.pi;
const gravity = 9.80665;

/// o arranjo da cauda
pub const Layout = enum {
    conventional,
    v_tail,
    tailless,
    h_tail,

    /// tem EH e EV separadas (a estática e o C_nβ são os mesmos)
    pub fn separate(layout: Layout) bool {
        return layout == .conventional or layout == .h_tail;
    }
};

/// C_Lα de uma asa finita (1/rad) a partir do a0 do perfil (Helmbold)
pub fn helmbold(section_slope: f64, aspect_ratio: f64) f64 {
    const ratio = section_slope / (pi * aspect_ratio);
    return section_slope / (@sqrt(1.0 + ratio * ratio) + ratio);
}

/// τ = dα/dδ de um flape simples (perfil fino) com o fator empírico 0,85
pub fn flapEffectiveness(chord_fraction: f64) f64 {
    const fraction = std.math.clamp(chord_fraction, 0.01, 0.99);
    const theta = std.math.acos(2 * fraction - 1);
    return 0.85 * (1 - (theta - @sin(theta)) / pi);
}

/// a asa de referência: a planta e os números da linha sustentadora
pub const Wing = struct {
    planform: *const wing_line.Planform,
    area: f64,
    mean_chord: f64,
    span: f64,
    aspect_ratio: f64,
    lift_slope: f64, // C_Lα (1/rad)
    lift_zero: f64, // C_L0
    moment: f64, // C_m,ac
    lift_max: f64,
    lift_cruise: f64,
    incidence: f64, // graus
    stall_speed: f64,
    aero_center: f64, // m atrás do bordo de ataque da raiz
    alpha: []const f64, // graus, a curva C_L × α
    lift: []const f64,
};

/// outra asa do avião (tandem): a planta, onde fica (recuo da raiz) e o C_Lα
pub const OtherWing = struct {
    planform: *const wing_line.Planform,
    shift: f64, // m, recuo do bordo de ataque da raiz em relação à referência
    lift_slope: f64,
    behind: bool, // atrás da referência: sente o downwash dela
};

/// um comando com ganho de arfagem numa asa (asa voadora, tandem)
pub const PitchStrip = struct {
    planform: *const wing_line.Planform,
    shift: f64,
    span_start: f64,
    span_end: f64,
    chord_fraction: f64,
    gain: f64,
};

/// o perfil da cauda, já com a montagem (invertido: o c_l troca de lado)
pub const TailAirfoil = struct {
    lift_slope: f64 = 2 * pi, // 1/rad
    alpha_zero: f64 = 0, // graus
    lift_low: f64 = -1.2, // c_l mín. 2D
    lift_high: f64 = 1.2, // c_l máx. 2D
};

/// o pedido: os parâmetros da etapa e as condições
pub const Input = struct {
    layout: Layout = .conventional,
    arm: f64 = 0.95,
    arm_from_cg: bool = false,
    tail_volume_h: f64 = 0.45,
    tail_volume_v: f64 = 0.04,
    aspect_h: f64 = 4.0,
    aspect_v: f64 = 1.6,
    taper_h: f64 = 1.0,
    taper_v: f64 = 0.7,
    elevator: f64 = 0.35,
    aileron_start: f64 = 0.55,
    aileron_end: f64 = 0.95,
    aileron_chord: f64 = 0.25,
    margin_target: f64 = 12, // % CMA
    margin_min: f64 = 5,
    eta: f64 = 0.9,
    boom_pitch: f64 = 0, // graus
    tip_fin: f64 = 0, // m, altura da deriva na ponta (sem cauda)
    tip_fin_chord: f64 = 0.6,
    tip_fin_rear: bool = true, // no tandem: as derivas na asa de trás
    horizontal: TailAirfoil = .{},
    vertical_slope: f64 = 2 * pi,
    // condições e regras
    mass: f64 = 10,
    density: f64 = 1.225,
    cruise_speed: f64 = 15,
    elevator_up: f64 = 20, // graus
    elevator_down: f64 = 15,
    aileron_up: f64 = 20,
    aileron_down: f64 = 12,
    gear_aft: f64 = 0.06, // m, trem principal atrás do CG
    tail_density: f64 = 0.7, // kg/m²
    boom_density: f64 = 0.12, // kg/m
};

pub const curve_speeds = 40;
pub const max_alphas = wing_line.max_alphas;

/// a geometria e a conta
pub const Result = struct {
    // geometria
    area_h: f64 = 0,
    area_v: f64 = 0,
    span_h: f64 = 0, // envergadura da EH (ou da cauda em V)
    height_v: f64 = 0, // altura de cada EV
    root_chord_h: f64 = 0,
    root_chord_v: f64 = 0,
    gamma: f64 = 0, // graus, diedro da cauda em V
    fins: u32 = 0, // EV (1 ou 2) ou derivas de ponta
    arm: f64 = 0, // m, do CA da asa ao da cauda
    tail_center: f64 = 0, // m, CA da cauda
    boom_length: f64 = 0,
    boom_start: f64 = 0, // m, 1/4 da corda da raiz da asa
    mass_tail: f64 = 0,
    mass_boom: f64 = 0,
    // estática
    downwash_slope: f64 = 0,
    h_ac: f64 = 0.25,
    h_n: f64 = 0,
    h_cg: f64 = 0,
    h_fwd: f64 = std.math.nan(f64),
    h_aft: f64 = std.math.nan(f64),
    x_cg: f64 = 0, // m atrás do bordo de ataque da raiz
    x_np: f64 = 0,
    tail_slope: f64 = 0, // a_h
    volume_h: f64 = 0,
    volume_v: f64 = 0,
    moment_elevator: f64 = 0, // C_mδe (1/rad)
    incidence_h: f64 = 0, // graus
    elevator_cruise: f64 = 0, // graus
    elevator_max_lift: f64 = 0,
    tail_lift_needed: f64 = std.math.nan(f64), // C_L da EH no C_L,max
    tail_lift_low: f64 = std.math.nan(f64),
    tail_lift_high: f64 = std.math.nan(f64),
    yaw_stability: f64 = std.math.nan(f64), // C_nβ (1/rad)
    arm_cg: f64 = 0,
    // rolagem
    roll_power: f64 = 0, // C_lδa
    roll_damping: f64 = 0, // C_lp
    roll_rate: f64 = 0, // p b / 2V
    // rotação na decolagem
    gear_x: f64 = 0,
    ground_lift: f64 = 0,
    rotation_speed: f64 = 0, // com o profundor todo
    rotation_speed_neutral: f64 = 0, // com δe = 0
    liftoff_speed: f64 = 0,
    // curvas: C_m × α e δe × V, no CG à frente, no alvo e atrás
    alpha_count: usize = 0,
    alpha: [max_alphas]f64 = undefined,
    moment: [3][max_alphas]f64 = undefined,
    speed: [curve_speeds]f64 = undefined,
    elevator: [3][curve_speeds]f64 = undefined,
    with_limits: bool = false, // as curvas [0] e [2] (CG à frente e atrás) valem
};

/// a conta da etapa (com o braço medido do CG, a cauda anda até a distância do CG ao CA dela ser o braço pedido:
/// ponto fixo, poucas voltas)
pub fn analyze(wing: Wing, others: []const OtherWing, strips: []const PitchStrip, input: Input, out: *Result) void {
    if (input.layout == .tailless or !input.arm_from_cg) return analyzeAt(wing, others, strips, input, 0, out);
    var shift: f64 = 0;
    for (0..30) |_| {
        analyzeAt(wing, others, strips, input, shift, out);
        const miss = input.arm - out.arm_cg;
        if (@abs(miss) < 1e-6) break;
        shift += miss;
    }
}

fn integrate(planform: *const wing_line.Planform, start: f64, end: f64, context: anytype, comptime term: fn (@TypeOf(context), f64, f64) f64) f64 {
    const count = 60;
    const semispan = planform.semispan;
    const low = start * semispan;
    const high = @min(end, 1.0) * semispan;
    var sum: f64 = 0;
    var previous = term(context, low, planform.chordAt(low));
    for (1..count) |i| {
        const y = low + (high - low) * @as(f64, @floatFromInt(i)) / @as(f64, count - 1);
        const value = term(context, y, planform.chordAt(y));
        sum += 0.5 * (previous + value) * (high - low) / @as(f64, count - 1);
        previous = value;
    }
    return sum;
}

fn analyzeAt(wing: Wing, others: []const OtherWing, strips: []const PitchStrip, input: Input, shift: f64, out: *Result) void {
    const area = wing.area;
    const chord = wing.mean_chord;
    const span = wing.span;
    const slope = wing.lift_slope;
    const mac_le = wing.aero_center - 0.25 * chord;
    const weight = input.mass * gravity;
    const dynamic = 0.5 * input.density * input.cruise_speed * input.cruise_speed;
    out.* = .{};
    out.h_ac = (wing.aero_center - mac_le) / chord;
    out.downwash_slope = 2 * slope / (pi * wing.aspect_ratio);
    out.boom_start = 0.25 * wing.planform.root_chord;

    // rolagem: C_lδa por faixas e C_lp de asa trapezoidal
    const tau_aileron = flapEffectiveness(input.aileron_chord);
    const moment_arm = integrate(wing.planform, input.aileron_start, @max(input.aileron_end, input.aileron_start + 0.05), {}, struct {
        fn term(_: void, y: f64, local: f64) f64 {
            return local * y;
        }
    }.term);
    out.roll_power = 2 * slope * tau_aileron / (area * span) * moment_arm;
    const taper = wing.planform.tip_chord / wing.planform.root_chord;
    out.roll_damping = -slope / 12 * (1 + 3 * taper) / (1 + taper);
    out.roll_rate = -out.roll_power * std.math.degreesToRadians(0.5 * (input.aileron_up + input.aileron_down)) / out.roll_damping;
    out.liftoff_speed = 1.1 * wing.stall_speed;
    out.ground_lift = wing.lift_zero + slope * std.math.degreesToRadians(wing.incidence);

    if (input.layout == .tailless) return tailless(wing, others, strips, input, mac_le, weight, out);

    // as áreas pelo volume de cauda (com o braço como foi dado) e a posição com o deslocamento
    const arm = input.arm + shift;
    const area_h = input.tail_volume_h * area * chord / input.arm;
    const area_v = input.tail_volume_v * area * span / input.arm;
    out.arm = arm;
    out.tail_center = wing.aero_center + arm;
    var tail_aspect: f64 = input.aspect_h;
    var tail_area = area_h;
    var projection: f64 = 1; // cos γ da cauda em V
    if (input.layout.separate()) {
        out.span_h = @sqrt(input.aspect_h * area_h);
        out.fins = if (input.layout == .h_tail) 2 else 1;
        const each = area_v / @as(f64, @floatFromInt(out.fins));
        out.height_v = @sqrt(input.aspect_v * each);
        out.root_chord_h = area_h / ((1 + input.taper_h) * out.span_h / 2);
        out.root_chord_v = 2 * each / ((1 + input.taper_v) * out.height_v);
    } else {
        tail_area = area_h + area_v;
        out.gamma = std.math.radiansToDegrees(std.math.atan(@sqrt(area_v / area_h)));
        out.span_h = @sqrt(input.aspect_h * tail_area);
        out.root_chord_h = tail_area / ((1 + input.taper_h) * out.span_h / 2);
        projection = @cos(std.math.degreesToRadians(out.gamma));
    }
    tail_aspect = out.span_h * out.span_h / tail_area;
    out.area_h = area_h;
    out.area_v = area_v;
    const boom_end = out.tail_center + 0.75 * out.root_chord_h; // o bordo de fuga da raiz da cauda
    out.boom_length = @max(boom_end - out.boom_start, 0.05) / @cos(std.math.degreesToRadians(input.boom_pitch));
    out.mass_tail = (area_h + area_v) * input.tail_density;
    out.mass_boom = out.boom_length * input.boom_density;

    var tail_slope = helmbold(input.horizontal.lift_slope, @max(tail_aspect, 0.5));
    if (input.layout == .v_tail) tail_slope *= projection * projection;
    const eta = input.eta;
    const volume = tail_area * arm / (area * chord);
    const h_n = out.h_ac + eta * volume * (tail_slope / slope) * (1 - out.downwash_slope);
    const h_cg = h_n - input.margin_target / 100;
    const tau = flapEffectiveness(input.elevator) / projection;
    const moment_elevator = -eta * volume * tail_slope * tau;
    const tail_zero = std.math.degreesToRadians(input.horizontal.alpha_zero) / projection;
    const low = 0.9 * projection * input.horizontal.lift_low;
    const high = 0.9 * projection * input.horizontal.lift_high;
    const statics: Statics = .{ .wing = wing, .slope = slope, .tail_slope = tail_slope, .volume = volume, .eta = eta, .tau = tau, .tail_zero = tail_zero, .low = low, .high = high, .projection = projection, .h_ac = out.h_ac, .aspect = wing.aspect_ratio };

    // incidência da EH: C_m = 0 no cruzeiro com δe = 0
    const cruise = wing.lift_cruise;
    const incidence = (wing.moment + cruise * (h_cg - out.h_ac)) / (eta * volume * tail_slope) - (statics.wingAlpha(cruise) - statics.downwash(cruise)) + tail_zero;
    const elevator_cruise = statics.trim(cruise, h_cg, incidence, moment_elevator);
    const elevator_max = statics.trim(wing.lift_max, h_cg, incidence, moment_elevator);
    const full_up = -std.math.degreesToRadians(input.elevator_up);
    const h_fwd = -statics.cm(wing.lift_max, full_up, incidence, 0) / wing.lift_max;

    out.tail_slope = tail_slope;
    out.volume_h = volume;
    out.h_n = h_n;
    out.h_cg = h_cg;
    out.x_cg = mac_le + h_cg * chord;
    out.x_np = mac_le + h_n * chord;
    out.moment_elevator = moment_elevator;
    out.incidence_h = std.math.radiansToDegrees(incidence);
    out.elevator_cruise = std.math.radiansToDegrees(elevator_cruise);
    out.elevator_max_lift = std.math.radiansToDegrees(elevator_max);
    out.tail_lift_needed = (wing.moment + wing.lift_max * (h_cg - out.h_ac)) / (eta * volume);
    out.tail_lift_low = low;
    out.tail_lift_high = high;
    out.h_fwd = h_fwd;
    out.h_aft = h_n - input.margin_min / 100;
    out.arm_cg = out.tail_center - out.x_cg;

    // rotação: a cauda no braço até o trem principal
    const gear = out.x_cg + input.gear_aft;
    out.gear_x = gear;
    const tail_share = volume * chord / arm; // S_h / S
    const ground = out.ground_lift;
    for ([_]f64{ full_up, 0 }, 0..) |deflection, k| {
        const tail_term = eta * tail_share * statics.tailLift(ground, deflection, incidence) * (gear - out.tail_center) / chord;
        const total = wing.moment + ground * (gear - wing.aero_center) / chord + tail_term;
        const speed = if (total > 0) @sqrt(2 * weight * input.gear_aft / (input.density * area * chord * total)) else std.math.inf(f64);
        if (k == 0) out.rotation_speed = speed else out.rotation_speed_neutral = speed;
    }

    // direcional
    if (input.layout.separate()) {
        const each = area_v / @as(f64, @floatFromInt(out.fins));
        const fin_slope = helmbold(input.vertical_slope, 1.55 * out.height_v * out.height_v / each);
        out.volume_v = area_v * arm / (area * span);
        out.yaw_stability = eta * out.volume_v * fin_slope;
    } else {
        const gamma = std.math.degreesToRadians(out.gamma);
        const fin_slope = tail_slope / @max(@cos(gamma) * @cos(gamma), 1e-3);
        out.volume_v = tail_area * @sin(gamma) * @sin(gamma) * arm / (area * span);
        out.yaw_stability = eta * out.volume_v * fin_slope;
    }
    curves(wing, input, dynamic, out, statics, incidence);
}

const Statics = struct {
    wing: Wing,
    slope: f64,
    tail_slope: f64,
    volume: f64,
    eta: f64,
    tau: f64,
    tail_zero: f64,
    low: f64,
    high: f64,
    projection: f64,
    h_ac: f64,
    aspect: f64,

    fn downwash(statics: Statics, lift: f64) f64 {
        return 2 * lift / (pi * statics.aspect);
    }
    fn wingAlpha(statics: Statics, lift: f64) f64 {
        return (lift - statics.wing.lift_zero) / statics.slope;
    }
    /// o C_L da cauda, limitado pelo estol dela (o profundor defletido sobe o c_l,max do lado dele: Δc_l,max ≈ 0,9
    /// com 45°; Raymer, cap. 12)
    fn tailLift(statics: Statics, lift: f64, deflection: f64, incidence: f64) f64 {
        const gain = 0.9 * 0.9 * statics.projection * @min(@abs(std.math.radiansToDegrees(deflection)) / 45.0, 1.0);
        const low = if (deflection < 0) statics.low - gain else statics.low;
        const high = if (deflection < 0) statics.high else statics.high + gain;
        return std.math.clamp(statics.tail_slope * (statics.wingAlpha(lift) - statics.downwash(lift) + incidence - statics.tail_zero + statics.tau * deflection), low, high);
    }
    fn cm(statics: Statics, lift: f64, deflection: f64, incidence: f64, h: f64) f64 {
        return statics.wing.moment + lift * (h - statics.h_ac) - statics.eta * statics.volume * statics.tailLift(lift, deflection, incidence);
    }
    /// o δe de equilíbrio (linear, sem o limite de estol da cauda)
    fn trim(statics: Statics, lift: f64, h: f64, incidence: f64, moment_elevator: f64) f64 {
        return -(statics.wing.moment + lift * (h - statics.h_ac) - statics.eta * statics.volume * statics.tail_slope * (statics.wingAlpha(lift) - statics.downwash(lift) + incidence - statics.tail_zero)) / moment_elevator;
    }
};

fn curves(wing: Wing, input: Input, dynamic: f64, out: *Result, statics: ?Statics, incidence: f64) void {
    _ = dynamic;
    const count = @min(wing.alpha.len, max_alphas);
    out.alpha_count = count;
    @memcpy(out.alpha[0..count], wing.alpha[0..count]);
    out.with_limits = statics != null;
    const places = [3]f64{ out.h_fwd, out.h_cg, out.h_aft };
    const stall = @max(wing.stall_speed, 1.0);
    for (0..curve_speeds) |i| out.speed[i] = stall + (2.2 * stall - stall) * @as(f64, @floatFromInt(i)) / @as(f64, curve_speeds - 1);
    for (places, 0..) |h, k| {
        if (statics == null and k != 1) continue;
        for (0..count) |i| out.moment[k][i] = if (statics) |known| known.cm(wing.lift[i], 0, incidence, h) else wing.moment + wing.lift[i] * (h - out.h_ac);
        for (0..curve_speeds) |i| {
            const speed = out.speed[i];
            const lift = input.mass * gravity / (0.5 * input.density * speed * speed * wing.area);
            const moment = if (statics) |known| known.cm(lift, 0, incidence, h) else wing.moment + lift * (h - out.h_ac);
            out.elevator[k][i] = std.math.radiansToDegrees(-moment / out.moment_elevator);
        }
    }
}

const StripTerm = struct { strip: PitchStrip, cg: f64, slope: f64, tau: f64, own: f64 };

fn stripTerm(context: StripTerm, y: f64, local: f64) f64 {
    const planform = context.strip.planform;
    const quarter = context.strip.shift + planform.offsetAt(y) + 0.25 * local;
    const arm = quarter - context.cg; // + atrás do CG
    return -context.slope * context.tau * local * arm + context.own * local * local;
}

fn tailless(wing: Wing, others: []const OtherWing, strips: []const PitchStrip, input: Input, mac_le: f64, weight: f64, out: *Result) void {
    const area = wing.area;
    const chord = wing.mean_chord;
    const slope = wing.lift_slope;
    var h_n = out.h_ac;
    // tandem: o ponto neutro é a média dos CA ponderada pela sustentação que cada asa ganha com α (a de trás com η e
    // o downwash da da frente): x_n = Σ a_i S_i x_ac,i / Σ a_i S_i (Etkin e Reid, seção 2.3; a conferir no PDF)
    var weighted = slope * area * wing.aero_center;
    var total = slope * area;
    for (others) |other| {
        const other_area = other.planform.area();
        const factor = if (other.behind) input.eta * (1 - out.downwash_slope) else 1.0;
        const gain = factor * other.lift_slope * other_area;
        weighted += gain * (other.shift + other.planform.aeroCenter());
        total += gain;
    }
    if (others.len > 0) h_n = (weighted / total - mac_le) / chord;
    const h_cg = h_n - input.margin_target / 100;
    const cg = mac_le + h_cg * chord;
    // cada comando com arfagem soma, com o ganho dele: Δc_l = a τ δ no quarto de corda da faixa e o momento próprio do
    // flape (perfil fino: Δc_m,c/4 = −½ sen θ_f (1 − cos θ_f) δ, com o fator 0,85; Anderson, "Fundamentals of
    // Aerodynamics", a conferir no PDF)
    var moment_control: f64 = 0;
    for (strips) |strip| {
        if (strip.gain == 0) continue;
        const theta = std.math.acos(std.math.clamp(2 * strip.chord_fraction - 1, -1.0, 1.0));
        const own = -0.85 * 0.5 * @sin(theta) * (1 - @cos(theta));
        const context: StripTerm = .{ .strip = strip, .cg = cg, .slope = slope, .tau = flapEffectiveness(strip.chord_fraction), .own = own };
        moment_control += strip.gain * 2 / (area * chord) * integrate(strip.planform, strip.span_start, strip.span_end, context, stripTerm);
    }
    if (moment_control == 0) moment_control = -1e-9;
    out.h_n = h_n;
    out.h_cg = h_cg;
    out.x_cg = cg;
    out.x_np = mac_le + h_n * chord;
    out.moment_elevator = moment_control;
    out.elevator_cruise = std.math.radiansToDegrees(-(wing.moment + wing.lift_cruise * (h_cg - out.h_ac)) / moment_control);
    out.elevator_max_lift = std.math.radiansToDegrees(-(wing.moment + wing.lift_max * (h_cg - out.h_ac)) / moment_control);
    const gear = cg + input.gear_aft;
    out.gear_x = gear;
    for ([_]f64{ -std.math.degreesToRadians(input.elevator_up), 0 }, 0..) |deflection, k| {
        const moment = wing.moment + out.ground_lift * (gear - wing.aero_center) / chord + moment_control * deflection;
        const speed = if (moment > 0) @sqrt(2 * weight * input.gear_aft / (input.density * area * chord * moment)) else std.math.inf(f64);
        if (k == 0) out.rotation_speed = speed else out.rotation_speed_neutral = speed;
    }
    // as derivas nas pontas: C_nβ = η V_V a_v com o braço do CG ao CA delas (alongamento de placa de ponta)
    if (input.tip_fin > 0) {
        var host = wing.planform;
        var host_shift: f64 = 0;
        if (input.tip_fin_rear) for (others) |other| if (other.behind) {
            host = other.planform;
            host_shift = other.shift;
            break;
        };
        const fin_root = input.tip_fin_chord * host.tip_chord;
        const fin_area = 2 * input.tip_fin * fin_root * (1 + input.taper_v) / 2;
        const fin_center = host_shift + host.offsetAt(host.semispan) + 0.25 * fin_root;
        const fin_slope = helmbold(5.9, 2 * input.tip_fin * input.tip_fin / @max(fin_area, 1e-9));
        out.fins = 2;
        out.area_v = fin_area;
        out.height_v = input.tip_fin;
        out.root_chord_v = fin_root;
        out.tail_center = fin_center;
        out.yaw_stability = fin_area * (fin_center - cg) / (area * wing.span) * fin_slope;
    }
    curves(wing, input, 0, out, null, 0);
}

test "empenagem convencional: ponto neutro atrás do CA e incidência negativa" {
    var planform = wing_line.planformOf(.{ .span = 2.4, .area = 0.9, .taper = 0.6, .rect_fraction = 0.5, .sweep = 0, .twist = -1.5 }, false);
    _ = &planform;
    const alphas = [_]f64{ -4, 0, 4, 8, 12 };
    const lifts = [_]f64{ 0.4, 0.8, 1.2, 1.6, 1.9 };
    const wing: Wing = .{ .planform = &planform, .area = planform.area(), .mean_chord = planform.meanChord(), .span = 2.4, .aspect_ratio = 2.4 * 2.4 / planform.area(), .lift_slope = 4.7, .lift_zero = 0.8, .moment = -0.25, .lift_max = 1.9, .lift_cruise = 1.0, .incidence = 2, .stall_speed = 9, .aero_center = planform.aeroCenter(), .alpha = &alphas, .lift = &lifts };
    var out: Result = .{};
    analyze(wing, &.{}, &.{}, .{ .mass = 12, .cruise_speed = 13 }, &out);
    try std.testing.expect(out.h_n > out.h_ac);
    try std.testing.expectApproxEqAbs(out.h_n - out.h_cg, 0.12, 1e-12);
    try std.testing.expect(out.area_h > 0 and out.area_v > 0);
    try std.testing.expect(out.yaw_stability > 0);
}
