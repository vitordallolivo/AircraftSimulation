//! A cadeia do mini-MDO para um tipo de aeronave e um provedor de tração, gerada em comptime:
//!
//!   x → geometria → polar → curva de tração (n motores) → PV
//!     → MTOW: a maior massa em que as restrições que dependem da massa (corrida, V_S, subida, V_max,
//!       T/W) ainda cumprem — o envelope dá as velocidades, a decolagem a corrida
//!     → no MTOW: CP = MTOW − PV, EE = CP/PV e todas as restrições → violação, pontuação
//!
//! `Thrust` é uma interface (`checkThrust`): `fn curve(self, set, n_motor) stages.Curve`.
//! `CoreThrust` usa o motor + hélice + bateria do núcleo (physics/propulsion); os testes usam mocks.
const std = @import("std");
const numerics = @import("../numerics.zig");
const types = @import("../types.zig");
const prop = @import("../physics/propulsion.zig");
const sizing_types = @import("types.zig");
const stages = @import("stages.zig");
const kinds = @import("kinds.zig");

/// confere em comptime que o provedor de tração tem `curve`
pub fn checkThrust(comptime ThrustProvider: type) void {
    if (!@hasDecl(ThrustProvider, "curve")) @compileError("provedor de tração " ++ @typeName(ThrustProvider) ++ " sem `curve`");
    _ = @as(fn (*ThrustProvider, *const sizing_types.PropSet, f64) stages.Curve, ThrustProvider.curve);
}

/// tração do núcleo: ponto de equilíbrio do motor com acelerador cheio, em cada V da grade
pub const CoreThrust = struct {
    p: *types.Params, // só env.rho e prop[0] são usados
    rho: f64,

    /// curva de tração T(V) do conjunto `set` com `n_motor` motores, pelo modelo do núcleo
    pub fn curve(self: *CoreThrust, set: *const sizing_types.PropSet, n_motor: f64) stages.Curve {
        self.p.env.rho = self.rho;
        self.p.n_prop = 1;
        self.p.prop[0] = set.unit;
        self.p.prop[0].tilt = 0;
        self.p.prop[0].toe = 0;
        self.p.prop[0].tilt_range = 0;
        prop.init(self.p);
        var curve_out: stages.Curve = .{ .V = stages.Curve.grid(), .T = undefined };
        for (curve_out.V, 0..) |airspeed, i| {
            const point = prop.point(self.p, &self.p.prop[0], airspeed, 1.0);
            curve_out.T[i] = if (std.math.isFinite(point.T)) @max(point.T, 0.0) * n_motor else 0.0;
        }
        return curve_out;
    }
};

/// mock: T = T0 (1 − V/Vz) por motor, com T0 = 10 N por kg do conjunto (nos testes)
pub const LinearThrust = struct {
    T0_per_kg: f64 = 25,
    Vz: f64 = 35,

    /// curva de tração linear do mock: T0 por kg do conjunto, zerando em Vz
    pub fn curve(self: *LinearThrust, set: *const sizing_types.PropSet, n_motor: f64) stages.Curve {
        return stages.linearCurve(self.T0_per_kg * set.mass * n_motor, self.Vz);
    }
};

/// `design_vars` decodificado: dentro dos limites; inteiros e listas arredondados
pub fn decode(cfg: *const sizing_types.SizingCfg, design_vars: []const f64, out: *[sizing_types.n_vars]f64) void {
    for (0..sizing_types.n_vars) |i| {
        const spec = cfg.vars[i];
        const lo = @min(spec.lo, spec.hi);
        const hi = @max(spec.lo, spec.hi);
        const value = if (i < design_vars.len and std.math.isFinite(design_vars[i])) design_vars[i] else lo;
        if (spec.kind == .continuous or lo == hi) {
            out[i] = std.math.clamp(value, lo, hi);
        } else { // inteiros e listas: inteiros dentro de [⌈lo⌉, ⌊hi⌋]
            const il = @ceil(lo);
            out[i] = std.math.clamp(@round(value), il, @max(@floor(hi), il));
        }
    }
    // listas: índice dentro do que existe
    out[sizing_types.variable(.airfoil)] = std.math.clamp(out[sizing_types.variable(.airfoil)], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[sizing_types.variable(.airfoil_tip)] = if (cfg.tip_same != 0) out[sizing_types.variable(.airfoil)] else std.math.clamp(out[sizing_types.variable(.airfoil_tip)], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[sizing_types.variable(.set)] = std.math.clamp(out[sizing_types.variable(.set)], 0, @as(f64, @floatFromInt(@max(cfg.n_sets, 1) - 1)));
    out[sizing_types.variable(.layout)] = std.math.clamp(out[sizing_types.variable(.layout)], 0, @as(f64, @floatFromInt(@max(cfg.n_layouts, 1) - 1)));
    out[sizing_types.variable(.motors)] = motorsFor(cfg.layouts[@intFromFloat(out[sizing_types.variable(.layout)])], out[sizing_types.variable(.motors)], cfg.vars[sizing_types.variable(.motors)]);
}

/// número de motores que o arranjo aceita, o mais perto do pedido (dentro dos limites da variável quando dá)
pub fn motorsFor(layout: sizing_types.LayoutData, want: f64, spec: sizing_types.VarSpec) f64 {
    const step: f64 = if (layout.n_step >= 2) 2.0 else 1.0;
    const lmin = @max(@round(layout.n_min), 1.0);
    const lmax = @max(@round(layout.n_max), lmin);
    var lo = @max(lmin, @ceil(@min(spec.lo, spec.hi)));
    var hi = @min(lmax, @floor(@max(spec.lo, spec.hi)));
    if (lo > hi) { // os limites da variável não cabem no arranjo: vale o arranjo
        lo = lmin;
        hi = lmax;
    }
    var motors = std.math.clamp(@round(if (std.math.isFinite(want)) want else lo), lo, hi);
    if (step == 2 and @mod(motors, 2) != 0) motors = if (motors + 1 <= hi) motors + 1 else @max(motors - 1, lmin);
    return @max(motors, 1);
}

/// a cadeia do dimensionamento para um tipo de aeronave e um provedor de tração
pub fn Chain(comptime AircraftKind: type, comptime ThrustProvider: type) type {
    comptime kinds.check(AircraftKind);
    comptime checkThrust(ThrustProvider);
    return struct {
        pub const Kind = AircraftKind;

        const Model = struct {
            geo: stages.Geo,
            pol: stages.Polar,
            curve: stages.Curve,
            ms: stages.Mass,
            tilt: f64,
        };

        /// grandezas que dependem da massa
        fn atMass(cfg: *const sizing_types.SizingCfg, model: *const Model, mass: f64, quantities: *[sizing_types.n_q]f64, hover: *bool, env: ?*stages.Env, with_ceiling: bool) void {
            const weight = mass * stages.g0;
            const env_point = stages.envelope(model.pol, &model.curve, weight, model.geo.S, cfg.rho);
            const hovers = AircraftKind.hover != .none and stages.canHover(&model.curve, mass, cfg.hover_margin);
            hover.* = hovers;
            quantities[sizing_types.quantity(.stall_speed)] = env_point.Vs;
            quantities[sizing_types.quantity(.max_speed)] = env_point.Vmax;
            quantities[sizing_types.quantity(.climb_rate)] = env_point.RC;
            quantities[sizing_types.quantity(.thrust_to_weight)] = env_point.TW;
            quantities[sizing_types.quantity(.best_glide_speed)] = env_point.V_LD;
            quantities[sizing_types.quantity(.max_lift_to_drag)] = env_point.LD;
            quantities[sizing_types.quantity(.takeoff_run)] = if (hovers) 0.0 else if (AircraftKind.hover == .required) std.math.inf(f64) else stages.takeoffRun(model.pol, &model.curve, mass, model.geo.S, cfg.rho, cfg.mu, model.tilt);
            const turn_speed = if (cfg.V_turn > 0) cfg.V_turn else 1.5 * env_point.Vs;
            quantities[sizing_types.quantity(.turn_load_factor)] = stages.sustainedN(model.pol, &model.curve, weight, model.geo.S, cfg.rho, turn_speed);
            quantities[sizing_types.quantity(.climb_gradient)] = 100.0 * env_point.grad;
            quantities[sizing_types.quantity(.landing_run)] = if (hovers) 0.0 else stages.landingRun(model.pol, weight, model.geo.S, cfg.rho, cfg.mu_brake);
            // o teto custa uma bisseção de envelopes: só quando alguém pede (restrição dele ou o resultado final)
            quantities[sizing_types.quantity(.ceiling)] = if (with_ceiling) stages.ceiling(model.pol, &model.curve, weight, model.geo.S, cfg.rho, cfg.roc_ceiling) else std.math.nan(f64);
            if (env) |env_out| env_out.* = env_point;
        }

        /// cumpre as restrições ativas que dependem da massa (e decola de algum jeito)
        fn massFeasible(cfg: *const sizing_types.SizingCfg, model: *const Model, mass: f64) bool {
            var quantities: [sizing_types.n_q]f64 = undefined;
            var hovers = false;
            const cons_count: usize = @intCast(std.math.clamp(cfg.n_cons, 0, sizing_types.max_cons));
            var need_ceiling = false;
            for (cfg.cons[0..cons_count]) |constraint| need_ceiling = need_ceiling or constraint.q == .ceiling;
            atMass(cfg, model, mass, &quantities, &hovers, null, need_ceiling);
            if (!std.math.isFinite(quantities[sizing_types.quantity(.takeoff_run)])) return false;
            for (cfg.cons[0..cons_count]) |constraint| {
                const which = sizing_types.constrained(constraint);
                if (sizing_types.massDependent(which) and sizing_types.violation(constraint, quantities[sizing_types.quantity(which)]) > 0) return false;
            }
            return true;
        }

        /// avalia um projeto: decodifica, monta geometria, polar e tração, acha o MTOW e confere as restrições
        pub fn eval(cfg: *const sizing_types.SizingCfg, thrust: *ThrustProvider, design_vars: []const f64) sizing_types.SizingOut {
            var out: sizing_types.SizingOut = .{};
            decode(cfg, design_vars, &out.x);
            const af = stages.blendAirfoils(cfg.airfoils[@intFromFloat(out.x[sizing_types.variable(.airfoil)])], cfg.airfoils[@intFromFloat(out.x[sizing_types.variable(.airfoil_tip)])], out.x[sizing_types.variable(.taper)]);
            const set = &cfg.sets[@intFromFloat(out.x[sizing_types.variable(.set)])];
            const n_motor = out.x[sizing_types.variable(.motors)];
            const lay = cfg.layouts[@intFromFloat(out.x[sizing_types.variable(.layout)])];
            var model: Model = undefined;
            model.geo = stages.geometry(AircraftKind, cfg, out.x[sizing_types.variable(.span)], out.x[sizing_types.variable(.area)]);
            model.pol = stages.polar(AircraftKind, cfg, model.geo, af, n_motor * lay.nacelle_CDS);
            model.curve = thrust.curve(set, n_motor);
            for (&model.curve.T) |*thrust_value| thrust_value.* *= std.math.clamp(lay.thrust_factor, 0.0, 1.5); // instalação do arranjo
            model.ms = stages.emptyMass(AircraftKind, cfg, model.geo, set.mass + @max(lay.mass_per_motor, 0.0), n_motor);
            model.tilt = std.math.degreesToRadians(out.x[sizing_types.variable(.tilt)]);
            const pv = model.ms.pv;
            // MTOW: bisseção na massa (as restrições de massa pioram com a massa)
            const top = @max(cfg.m_max, pv);
            var mtow = pv;
            const ok_pv = massFeasible(cfg, &model, pv);
            if (ok_pv) {
                if (massFeasible(cfg, &model, top)) {
                    mtow = top;
                } else {
                    var lo = pv;
                    var hi = top;
                    for (0..numerics.count(numerics.active.chain_bisections)) |_| {
                        const mid = 0.5 * (lo + hi);
                        if (massFeasible(cfg, &model, mid)) lo = mid else hi = mid;
                        if (hi - lo < 1e-4 * hi) break;
                    }
                    mtow = lo;
                }
            }
            var env: stages.Env = undefined;
            var hover = false;
            atMass(cfg, &model, mtow, &out.q, &hover, &env, true);
            out.hover = @intFromBool(hover);
            out.CD0, out.K, out.CLmax, out.CLg = .{ model.pol.CD0, model.pol.K, model.pol.CLmax, model.pol.CLg };
            out.q[sizing_types.quantity(.area)] = model.geo.S;
            out.q[sizing_types.quantity(.span)] = model.geo.b;
            out.q[sizing_types.quantity(.aspect_ratio)] = model.geo.AR;
            out.q[sizing_types.quantity(.root_chord)] = 2.0 * model.geo.c / (1.0 + std.math.clamp(out.x[sizing_types.variable(.taper)], 0.05, 1.0)); // c média → raiz
            out.q[sizing_types.quantity(.surface_count)] = @floatFromInt(AircraftKind.surfaces(cfg));
            out.q[sizing_types.quantity(.motor_power)] = set.P_max * n_motor;
            out.q[sizing_types.quantity(.motor_count)] = n_motor;
            out.q[sizing_types.quantity(.mass)] = mtow;
            out.q[sizing_types.quantity(.mtow)] = mtow;
            out.q[sizing_types.quantity(.empty_mass)] = pv;
            out.q[sizing_types.quantity(.payload)] = mtow - pv;
            out.q[sizing_types.quantity(.structural_efficiency)] = (mtow - pv) / pv;
            out.V = model.curve.V;
            out.T = model.curve.T;
            out.D = env.D;
            // violação: todas as restrições ativas no MTOW; sem decolar ou sem carga paga também conta
            var viol: f64 = if (ok_pv) 0.0 else 1.0;
            const cons_count: usize = @intCast(std.math.clamp(cfg.n_cons, 0, sizing_types.max_cons));
            for (cfg.cons[0..cons_count]) |constraint| {
                viol += sizing_types.violation(constraint, out.q[sizing_types.quantity(sizing_types.constrained(constraint))]);
            }
            if (!std.math.isFinite(viol)) viol = 1e3;
            out.violation = viol;
            out.feasible = @intFromBool(ok_pv and viol <= 1e-9);
            out.score = if (cfg.objective == .structural_efficiency) out.q[sizing_types.quantity(.structural_efficiency)] else mtow;
            return out;
        }
    };
}

// ------------------------------------------------------------------ testes (tração mock)
const testing = std.testing;
const fuzz = @import("../util/fuzz.zig");

fn baseCfg() sizing_types.SizingCfg {
    var cfg: sizing_types.SizingCfg = .{};
    cfg.vars[sizing_types.variable(.span)] = .{ .lo = 2.0, .hi = 2.0 };
    cfg.vars[sizing_types.variable(.area)] = .{ .lo = 0.8, .hi = 0.8 };
    cfg.vars[sizing_types.variable(.taper)] = .{ .lo = 0.6, .hi = 0.6 };
    cfg.vars[sizing_types.variable(.motors)] = .{ .lo = 1, .hi = 1, .kind = .integer };
    cfg.sets[0].mass = 0.9;
    cfg.cons[0] = .{ .q = .takeoff_run, .op = .at_most, .value = 40 };
    cfg.n_cons = 1;
    return cfg;
}

test "MTOW pela corrida: no MTOW a corrida bate a restrição" {
    var cfg = baseCfg();
    var thrust: LinearThrust = .{};
    const out = Chain(kinds.Conventional, LinearThrust).eval(&cfg, &thrust, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    try testing.expect(out.feasible == 1);
    try testing.expectApproxEqRel(@as(f64, 40), out.q[sizing_types.quantity(.takeoff_run)], 0.01);
    try testing.expectApproxEqAbs(out.q[sizing_types.quantity(.mtow)] - out.q[sizing_types.quantity(.empty_mass)], out.q[sizing_types.quantity(.payload)], 1e-12);
}

test "corrida de 3 m: monoplano não cumpre; VTOL que paira decola na vertical" {
    var cfg = baseCfg();
    cfg.cons[0].value = 3;
    cfg.sets[0].mass = 3; // tração estática de 75 N por motor no mock
    var thrust: LinearThrust = .{};
    const design_vars = [_]f64{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 };
    const mono = Chain(kinds.Conventional, LinearThrust).eval(&cfg, &thrust, &design_vars);
    const vtol = Chain(kinds.Vtol, LinearThrust).eval(&cfg, &thrust, &design_vars);
    try testing.expect(mono.feasible == 0);
    try testing.expect(vtol.feasible == 1 and vtol.hover == 1 and vtol.q[sizing_types.quantity(.takeoff_run)] == 0);
    // pairado: MTOW = T0 / (margem g)
    try testing.expectApproxEqRel(75.0 / (cfg.hover_margin * stages.g0), vtol.q[sizing_types.quantity(.mtow)], 1e-3);
}

test "duas asas: mesma envergadura e área, menos arrasto induzido → mais L/D" {
    var cfg = baseCfg();
    var thrust: LinearThrust = .{};
    const design_vars = [_]f64{ 1.5, 0.9, 0.6, 0, 0, 1, 0, 0, 0 };
    const mono = Chain(kinds.Conventional, LinearThrust).eval(&cfg, &thrust, &design_vars);
    var c2 = cfg;
    c2.n_cons = 0;
    c2.m_max = mono.q[sizing_types.quantity(.mtow)]; // compara na mesma massa
    const mono_same = Chain(kinds.Conventional, LinearThrust).eval(&c2, &thrust, &design_vars);
    var c3 = c2;
    c3.wing_count = 2;
    const two_wings = Chain(kinds.Conventional, LinearThrust).eval(&c3, &thrust, &design_vars);
    try testing.expect(two_wings.q[sizing_types.quantity(.max_lift_to_drag)] > mono_same.q[sizing_types.quantity(.max_lift_to_drag)]);
}

fn fuzzChain(_: void, src: *fuzz.Src) !void {
    var cfg = baseCfg();
    cfg.vars[sizing_types.variable(.span)] = .{ .lo = 0.5, .hi = 4 };
    cfg.vars[sizing_types.variable(.area)] = .{ .lo = 0.1, .hi = 2 };
    cfg.vars[sizing_types.variable(.motors)] = .{ .lo = 1, .hi = 4, .kind = .integer };
    cfg.vars[sizing_types.variable(.tilt)] = .{ .lo = 0, .hi = 12 };
    cfg.vars[sizing_types.variable(.set)] = .{ .lo = 0, .hi = 1, .kind = .list };
    cfg.n_sets = 2;
    cfg.sets[1].mass = src.range(0.1, 3);
    cfg.mu = src.range(0, 0.1);
    cfg.rho = src.range(0.8, 1.3);
    cfg.cons[0].value = src.range(1, 120);
    cfg.cons[1] = .{ .q = .stall_speed, .op = .at_most, .value = src.range(6, 20) };
    cfg.cons[2] = .{ .q = .structural_efficiency, .op = .at_least, .value = src.range(0, 2) };
    cfg.n_cons = @intCast(src.int(u32, 0, 3));
    cfg.n_airfoils = 2;
    cfg.airfoils[1] = .{ .clmax = src.range(0.8, 2.4), .cd0 = src.range(0.005, 0.03) };
    cfg.tip_same = @intFromBool(src.boolean());
    cfg.vars[sizing_types.variable(.airfoil)] = .{ .lo = 0, .hi = 1, .kind = .list };
    cfg.vars[sizing_types.variable(.airfoil_tip)] = .{ .lo = 0, .hi = 1, .kind = .list };
    cfg.n_layouts = 3; // nariz (1), asa (pares), propulsora (1, esteira)
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 4, .n_step = 2, .nacelle_CDS = src.range(0, 0.01), .mass_per_motor = src.range(0, 0.3) };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = src.range(0.7, 1) };
    cfg.vars[sizing_types.variable(.layout)] = .{ .lo = 0, .hi = 2, .kind = .list };
    var thrust: LinearThrust = .{ .T0_per_kg = src.range(5, 60), .Vz = src.range(10, 60) };
    var design_vars: [sizing_types.n_vars]f64 = undefined;
    for (&design_vars) |*value| value.* = src.mostly(-2, 6);
    inline for (kinds.all) |AircraftKind| {
        const out = Chain(AircraftKind, LinearThrust).eval(&cfg, &thrust, &design_vars);
        // o vetor usado respeita os limites e os tipos
        for (0..sizing_types.n_vars) |i| {
            try testing.expect(out.x[i] >= @min(cfg.vars[i].lo, cfg.vars[i].hi) - 1e-12 and out.x[i] <= @max(cfg.vars[i].lo, cfg.vars[i].hi) + 1e-12);
        }
        try testing.expect(out.x[sizing_types.variable(.motors)] == @round(out.x[sizing_types.variable(.motors)]));
        if (cfg.tip_same != 0) try testing.expectEqual(out.x[sizing_types.variable(.airfoil)], out.x[sizing_types.variable(.airfoil_tip)]);
        // o número de motores respeita o arranjo (na asa: pares)
        const layout = cfg.layouts[@intFromFloat(out.x[sizing_types.variable(.layout)])];
        try testing.expect(out.x[sizing_types.variable(.motors)] >= layout.n_min and out.x[sizing_types.variable(.motors)] <= layout.n_max);
        if (layout.n_step == 2) try testing.expect(@mod(out.x[sizing_types.variable(.motors)], 2) == 0);
        try testing.expect(out.q[sizing_types.quantity(.mtow)] >= out.q[sizing_types.quantity(.empty_mass)] - 1e-9 and out.violation >= 0);
        try testing.expect(std.math.isFinite(out.score));
        // no MTOW as restrições de massa cumprem; um pouco acima, alguma falha (se não bateu no teto)
        if (out.feasible == 1 and out.q[sizing_types.quantity(.mtow)] < cfg.m_max * 0.999) {
            var c2 = cfg;
            c2.vars[sizing_types.variable(.span)] = .{ .lo = out.x[sizing_types.variable(.span)], .hi = out.x[sizing_types.variable(.span)] };
            c2.vars[sizing_types.variable(.area)] = .{ .lo = out.x[sizing_types.variable(.area)], .hi = out.x[sizing_types.variable(.area)] };
            const repeat = Chain(AircraftKind, LinearThrust).eval(&c2, &thrust, &out.x);
            try testing.expectApproxEqRel(out.q[sizing_types.quantity(.mtow)], repeat.q[sizing_types.quantity(.mtow)], 1e-9); // determinística
        }
    }
}

test "fuzz: cadeia inteira com tração mock, todos os tipos" {
    try fuzz.checkScaled({}, fuzzChain, .{}, 4);
}

test "curva sustentada como restrição: n ≥ 2 baixa o MTOW" {
    var cfg = baseCfg();
    var thrust: LinearThrust = .{};
    const MonoChain = Chain(kinds.Conventional, LinearThrust);
    const design_vars = [_]f64{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 };
    const free = MonoChain.eval(&cfg, &thrust, &design_vars);
    cfg.cons[1] = .{ .q = .turn_load_factor, .op = .at_least, .value = 2.0 };
    cfg.n_cons = 2;
    const turn = MonoChain.eval(&cfg, &thrust, &design_vars);
    try testing.expect(turn.q[sizing_types.quantity(.mtow)] < free.q[sizing_types.quantity(.mtow)]);
    try testing.expect(turn.feasible == 1 and turn.q[sizing_types.quantity(.turn_load_factor)] >= 2.0 - 1e-6);
    try testing.expect(std.math.isFinite(turn.q[sizing_types.quantity(.ceiling)]) or std.math.isNan(turn.q[sizing_types.quantity(.ceiling)]));
}

test "corda da raiz: retangular = S/b; afilada é maior" {
    var cfg = baseCfg();
    var thrust: LinearThrust = .{};
    const MonoChain = Chain(kinds.Conventional, LinearThrust);
    cfg.vars[sizing_types.variable(.taper)] = .{ .lo = 1, .hi = 1 };
    const rect = MonoChain.eval(&cfg, &thrust, &.{ 2.0, 0.8, 1.0, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4), rect.q[sizing_types.quantity(.root_chord)], 1e-12);
    cfg.vars[sizing_types.variable(.taper)] = .{ .lo = 0.5, .hi = 0.5 };
    const tapered = MonoChain.eval(&cfg, &thrust, &.{ 2.0, 0.8, 0.5, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4 * 2 / 1.5), tapered.q[sizing_types.quantity(.root_chord)], 1e-12);
}

test "arranjo: propulsora na esteira perde tração; naceles somam arrasto e massa" {
    var cfg = baseCfg();
    cfg.n_layouts = 3;
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 2, .n_step = 2, .nacelle_CDS = 0.004, .mass_per_motor = 0.15 };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = 0.85 };
    cfg.vars[sizing_types.variable(.motors)] = .{ .lo = 1, .hi = 4, .kind = .integer };
    cfg.vars[sizing_types.variable(.layout)] = .{ .lo = 0, .hi = 2, .kind = .list };
    var thrust: LinearThrust = .{};
    const MonoChain = Chain(kinds.Conventional, LinearThrust);
    const nose = MonoChain.eval(&cfg, &thrust, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    const push = MonoChain.eval(&cfg, &thrust, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 2 });
    const wing = MonoChain.eval(&cfg, &thrust, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 1 }); // pediu 1: na asa vira 2
    try testing.expectApproxEqRel(0.85 * nose.T[0], push.T[0], 1e-12);
    try testing.expect(push.q[sizing_types.quantity(.mtow)] < nose.q[sizing_types.quantity(.mtow)]);
    try testing.expectEqual(@as(f64, 2), wing.x[sizing_types.variable(.motors)]);
    try testing.expectApproxEqAbs(nose.q[sizing_types.quantity(.empty_mass)] + cfg.sets[0].mass + 2 * 0.15, wing.q[sizing_types.quantity(.empty_mass)], 1e-9);
}

test "tração do núcleo: estática positiva e caindo com V" {
    const params = try testing.allocator.create(types.Params);
    defer testing.allocator.destroy(params);
    params.* = .{};
    var set: sizing_types.PropSet = .{};
    set.unit = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 2 };
    set.unit.J[1] = 0.68;
    set.unit.CT[0] = 0.09;
    set.unit.CP[0] = 0.03;
    set.unit.CP[1] = 0.006;
    var thrust: CoreThrust = .{ .p = params, .rho = 1.2 };
    const curve_two = thrust.curve(&set, 2);
    try testing.expect(curve_two.T[0] > 10 and curve_two.T[10] < curve_two.T[0]);
    const one = thrust.curve(&set, 1);
    try testing.expectApproxEqRel(curve_two.T[0], 2 * one.T[0], 1e-12);
}
