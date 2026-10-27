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
const types = @import("../types.zig");
const prop = @import("../physics/propulsion.zig");
const sizing_types = @import("types.zig");
const stages = @import("stages.zig");
const kinds = @import("kinds.zig");

pub fn checkThrust(comptime Th: type) void {
    if (!@hasDecl(Th, "curve")) @compileError("provedor de tração " ++ @typeName(Th) ++ " sem `curve`");
    _ = @as(fn (*Th, *const sizing_types.PropSet, f64) stages.Curve, Th.curve);
}

/// tração do núcleo: ponto de equilíbrio do motor com acelerador cheio, em cada V da grade
pub const CoreThrust = struct {
    p: *types.Params, // só env.rho e prop[0] são usados
    rho: f64,

    pub fn curve(self: *CoreThrust, set: *const sizing_types.PropSet, n_motor: f64) stages.Curve {
        self.p.env.rho = self.rho;
        self.p.n_prop = 1;
        self.p.prop[0] = set.unit;
        self.p.prop[0].tilt = 0;
        self.p.prop[0].toe = 0;
        self.p.prop[0].tilt_range = 0;
        prop.init(self.p);
        var c: stages.Curve = .{ .V = stages.Curve.grid(), .T = undefined };
        for (c.V, 0..) |V, i| {
            const pt = prop.point(self.p, &self.p.prop[0], V, 1.0);
            c.T[i] = if (std.math.isFinite(pt.T)) @max(pt.T, 0.0) * n_motor else 0.0;
        }
        return c;
    }
};

/// mock: T = T0 (1 − V/Vz) por motor, com T0 = 10 N por kg do conjunto (nos testes)
pub const LinearThrust = struct {
    T0_per_kg: f64 = 25,
    Vz: f64 = 35,

    pub fn curve(self: *LinearThrust, set: *const sizing_types.PropSet, n_motor: f64) stages.Curve {
        return stages.linearCurve(self.T0_per_kg * set.mass * n_motor, self.Vz);
    }
};

/// x decodificado: dentro dos limites; inteiros e listas arredondados
pub fn decode(cfg: *const sizing_types.SizingCfg, x: []const f64, out: *[sizing_types.n_vars]f64) void {
    for (0..sizing_types.n_vars) |i| {
        const v = cfg.vars[i];
        const lo = @min(v.lo, v.hi);
        const hi = @max(v.lo, v.hi);
        const y = if (i < x.len and std.math.isFinite(x[i])) x[i] else lo;
        if (v.kind == sizing_types.var_continuous or lo == hi) {
            out[i] = std.math.clamp(y, lo, hi);
        } else { // inteiros e listas: inteiros dentro de [⌈lo⌉, ⌊hi⌋]
            const il = @ceil(lo);
            out[i] = std.math.clamp(@round(y), il, @max(@floor(hi), il));
        }
    }
    // listas: índice dentro do que existe
    out[sizing_types.v_airfoil] = std.math.clamp(out[sizing_types.v_airfoil], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[sizing_types.v_airfoil_tip] = if (cfg.tip_same != 0) out[sizing_types.v_airfoil] else std.math.clamp(out[sizing_types.v_airfoil_tip], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[sizing_types.v_set] = std.math.clamp(out[sizing_types.v_set], 0, @as(f64, @floatFromInt(@max(cfg.n_sets, 1) - 1)));
    out[sizing_types.v_layout] = std.math.clamp(out[sizing_types.v_layout], 0, @as(f64, @floatFromInt(@max(cfg.n_layouts, 1) - 1)));
    out[sizing_types.v_motors] = motorsFor(cfg.layouts[@intFromFloat(out[sizing_types.v_layout])], out[sizing_types.v_motors], cfg.vars[sizing_types.v_motors]);
}

/// número de motores que o arranjo aceita, o mais perto do pedido (dentro dos limites da variável quando dá)
pub fn motorsFor(l: sizing_types.LayoutData, want: f64, v: sizing_types.VarSpec) f64 {
    const step: f64 = if (l.n_step >= 2) 2.0 else 1.0;
    const lmin = @max(@round(l.n_min), 1.0);
    const lmax = @max(@round(l.n_max), lmin);
    var lo = @max(lmin, @ceil(@min(v.lo, v.hi)));
    var hi = @min(lmax, @floor(@max(v.lo, v.hi)));
    if (lo > hi) { // os limites da variável não cabem no arranjo: vale o arranjo
        lo = lmin;
        hi = lmax;
    }
    var n = std.math.clamp(@round(if (std.math.isFinite(want)) want else lo), lo, hi);
    if (step == 2 and @mod(n, 2) != 0) n = if (n + 1 <= hi) n + 1 else @max(n - 1, lmin);
    return @max(n, 1);
}

pub fn Chain(comptime K: type, comptime Th: type) type {
    comptime kinds.check(K);
    comptime checkThrust(Th);
    return struct {
        pub const Kind = K;

        const Model = struct {
            geo: stages.Geo,
            pol: stages.Polar,
            curve: stages.Curve,
            ms: stages.Mass,
            tilt: f64,
        };

        /// grandezas que dependem da massa
        fn atMass(cfg: *const sizing_types.SizingCfg, md: *const Model, m: f64, q: *[sizing_types.n_q]f64, hover: *bool, env: ?*stages.Env, with_ceiling: bool) void {
            const W = m * stages.g0;
            const e = stages.envelope(md.pol, &md.curve, W, md.geo.S, cfg.rho);
            const h = K.hover != .none and stages.canHover(&md.curve, m, cfg.hover_margin);
            hover.* = h;
            q[sizing_types.q_VS] = e.Vs;
            q[sizing_types.q_Vmax] = e.Vmax;
            q[sizing_types.q_RC] = e.RC;
            q[sizing_types.q_TW] = e.TW;
            q[sizing_types.q_V_LD] = e.V_LD;
            q[sizing_types.q_LD] = e.LD;
            q[sizing_types.q_s_to] = if (h) 0.0 else if (K.hover == .required) std.math.inf(f64) else stages.takeoffRun(md.pol, &md.curve, m, md.geo.S, cfg.rho, cfg.mu, md.tilt);
            const Vt = if (cfg.V_turn > 0) cfg.V_turn else 1.5 * e.Vs;
            q[sizing_types.q_n_turn] = stages.sustainedN(md.pol, &md.curve, W, md.geo.S, cfg.rho, Vt);
            q[sizing_types.q_grad] = 100.0 * e.grad;
            q[sizing_types.q_s_land] = if (h) 0.0 else stages.landingRun(md.pol, W, md.geo.S, cfg.rho, cfg.mu_brake);
            // o teto custa uma bisseção de envelopes: só quando alguém pede (restrição dele ou o resultado final)
            q[sizing_types.q_ceiling] = if (with_ceiling) stages.ceiling(md.pol, &md.curve, W, md.geo.S, cfg.rho, cfg.roc_ceiling) else std.math.nan(f64);
            if (env) |p| p.* = e;
        }

        /// cumpre as restrições ativas que dependem da massa (e decola de algum jeito)
        fn massFeasible(cfg: *const sizing_types.SizingCfg, md: *const Model, m: f64) bool {
            var q: [sizing_types.n_q]f64 = undefined;
            var h = false;
            const n: usize = @intCast(std.math.clamp(cfg.n_cons, 0, sizing_types.max_cons));
            var need_ceiling = false;
            for (cfg.cons[0..n]) |c| need_ceiling = need_ceiling or c.q == sizing_types.q_ceiling;
            atMass(cfg, md, m, &q, &h, null, need_ceiling);
            if (!std.math.isFinite(q[sizing_types.q_s_to])) return false;
            for (cfg.cons[0..n]) |c| {
                const k: usize = @intCast(std.math.clamp(c.q, 0, sizing_types.n_q - 1));
                if (sizing_types.massDependent(k) and sizing_types.violation(c, q[k]) > 0) return false;
            }
            return true;
        }

        pub fn eval(cfg: *const sizing_types.SizingCfg, thrust: *Th, x: []const f64) sizing_types.SizingOut {
            var o: sizing_types.SizingOut = .{};
            decode(cfg, x, &o.x);
            const af = stages.blendAirfoils(cfg.airfoils[@intFromFloat(o.x[sizing_types.v_airfoil])], cfg.airfoils[@intFromFloat(o.x[sizing_types.v_airfoil_tip])], o.x[sizing_types.v_taper]);
            const set = &cfg.sets[@intFromFloat(o.x[sizing_types.v_set])];
            const n_motor = o.x[sizing_types.v_motors];
            const lay = cfg.layouts[@intFromFloat(o.x[sizing_types.v_layout])];
            var md: Model = undefined;
            md.geo = stages.geometry(K, o.x[sizing_types.v_span], o.x[sizing_types.v_area]);
            md.pol = stages.polar(K, cfg, md.geo, af, n_motor * lay.nacelle_CDS);
            md.curve = thrust.curve(set, n_motor);
            for (&md.curve.T) |*t| t.* *= std.math.clamp(lay.thrust_factor, 0.0, 1.5); // instalação do arranjo
            md.ms = stages.emptyMass(K, cfg, md.geo, set.mass + @max(lay.mass_per_motor, 0.0), n_motor);
            md.tilt = std.math.degreesToRadians(o.x[sizing_types.v_tilt]);
            const pv = md.ms.pv;
            // MTOW: bisseção na massa (as restrições de massa pioram com a massa)
            const top = @max(cfg.m_max, pv);
            var mtow = pv;
            const ok_pv = massFeasible(cfg, &md, pv);
            if (ok_pv) {
                if (massFeasible(cfg, &md, top)) {
                    mtow = top;
                } else {
                    var lo = pv;
                    var hi = top;
                    for (0..40) |_| {
                        const mid = 0.5 * (lo + hi);
                        if (massFeasible(cfg, &md, mid)) lo = mid else hi = mid;
                        if (hi - lo < 1e-4 * hi) break;
                    }
                    mtow = lo;
                }
            }
            var env: stages.Env = undefined;
            var hover = false;
            atMass(cfg, &md, mtow, &o.q, &hover, &env, true);
            o.hover = @intFromBool(hover);
            o.CD0, o.K, o.CLmax, o.CLg = .{ md.pol.CD0, md.pol.K, md.pol.CLmax, md.pol.CLg };
            o.q[sizing_types.q_S] = md.geo.S;
            o.q[sizing_types.q_b] = md.geo.b;
            o.q[sizing_types.q_AR] = md.geo.AR;
            o.q[sizing_types.q_c_root] = 2.0 * md.geo.c / (1.0 + std.math.clamp(o.x[sizing_types.v_taper], 0.05, 1.0)); // c média → raiz
            o.q[sizing_types.q_n_surf] = @floatFromInt(K.surfaces());
            o.q[sizing_types.q_P] = set.P_max * n_motor;
            o.q[sizing_types.q_n_motor] = n_motor;
            o.q[sizing_types.q_mass] = mtow;
            o.q[sizing_types.q_mtow] = mtow;
            o.q[sizing_types.q_pv] = pv;
            o.q[sizing_types.q_cp] = mtow - pv;
            o.q[sizing_types.q_ee] = (mtow - pv) / pv;
            o.V = md.curve.V;
            o.T = md.curve.T;
            o.D = env.D;
            // violação: todas as restrições ativas no MTOW; sem decolar ou sem carga paga também conta
            var viol: f64 = if (ok_pv) 0.0 else 1.0;
            const n: usize = @intCast(std.math.clamp(cfg.n_cons, 0, sizing_types.max_cons));
            for (cfg.cons[0..n]) |c| {
                const k: usize = @intCast(std.math.clamp(c.q, 0, sizing_types.n_q - 1));
                viol += sizing_types.violation(c, o.q[k]);
            }
            if (!std.math.isFinite(viol)) viol = 1e3;
            o.violation = viol;
            o.feasible = @intFromBool(ok_pv and viol <= 1e-9);
            o.score = if (cfg.objective == sizing_types.obj_ee) o.q[sizing_types.q_ee] else mtow;
            return o;
        }
    };
}

// ------------------------------------------------------------------ testes (tração mock)
const testing = std.testing;
const fuzz = @import("../util/fuzz.zig");

fn baseCfg() sizing_types.SizingCfg {
    var c: sizing_types.SizingCfg = .{};
    c.vars[sizing_types.v_span] = .{ .lo = 2.0, .hi = 2.0 };
    c.vars[sizing_types.v_area] = .{ .lo = 0.8, .hi = 0.8 };
    c.vars[sizing_types.v_taper] = .{ .lo = 0.6, .hi = 0.6 };
    c.vars[sizing_types.v_motors] = .{ .lo = 1, .hi = 1, .kind = sizing_types.var_integer };
    c.sets[0].mass = 0.9;
    c.cons[0] = .{ .q = sizing_types.q_s_to, .op = sizing_types.op_le, .value = 40 };
    c.n_cons = 1;
    return c;
}

test "MTOW pela corrida: no MTOW a corrida bate a restrição" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const o = Chain(kinds.Monoplane, LinearThrust).eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    try testing.expect(o.feasible == 1);
    try testing.expectApproxEqRel(@as(f64, 40), o.q[sizing_types.q_s_to], 0.01);
    try testing.expectApproxEqAbs(o.q[sizing_types.q_mtow] - o.q[sizing_types.q_pv], o.q[sizing_types.q_cp], 1e-12);
}

test "corrida de 3 m: monoplano não cumpre; VTOL que paira decola na vertical" {
    var cfg = baseCfg();
    cfg.cons[0].value = 3;
    cfg.sets[0].mass = 3; // tração estática de 75 N por motor no mock
    var th: LinearThrust = .{};
    const x = [_]f64{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 };
    const mono = Chain(kinds.Monoplane, LinearThrust).eval(&cfg, &th, &x);
    const vtol = Chain(kinds.Vtol, LinearThrust).eval(&cfg, &th, &x);
    try testing.expect(mono.feasible == 0);
    try testing.expect(vtol.feasible == 1 and vtol.hover == 1 and vtol.q[sizing_types.q_s_to] == 0);
    // pairado: MTOW = T0 / (margem g)
    try testing.expectApproxEqRel(75.0 / (cfg.hover_margin * stages.g0), vtol.q[sizing_types.q_mtow], 1e-3);
}

test "biplano: mesma envergadura e área, menos arrasto induzido → mais subida" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const x = [_]f64{ 1.5, 0.9, 0.6, 0, 0, 1, 0, 0, 0 };
    const mono = Chain(kinds.Monoplane, LinearThrust).eval(&cfg, &th, &x);
    var c2 = cfg;
    c2.n_cons = 0;
    c2.m_max = mono.q[sizing_types.q_mtow]; // compara na mesma massa
    const a = Chain(kinds.Monoplane, LinearThrust).eval(&c2, &th, &x);
    const b = Chain(kinds.Biplane, LinearThrust).eval(&c2, &th, &x);
    try testing.expect(b.q[sizing_types.q_LD] > a.q[sizing_types.q_LD]);
}

fn fuzzChain(_: void, src: *fuzz.Src) !void {
    var cfg = baseCfg();
    cfg.vars[sizing_types.v_span] = .{ .lo = 0.5, .hi = 4 };
    cfg.vars[sizing_types.v_area] = .{ .lo = 0.1, .hi = 2 };
    cfg.vars[sizing_types.v_motors] = .{ .lo = 1, .hi = 4, .kind = sizing_types.var_integer };
    cfg.vars[sizing_types.v_tilt] = .{ .lo = 0, .hi = 12 };
    cfg.vars[sizing_types.v_set] = .{ .lo = 0, .hi = 1, .kind = sizing_types.var_list };
    cfg.n_sets = 2;
    cfg.sets[1].mass = src.range(0.1, 3);
    cfg.mu = src.range(0, 0.1);
    cfg.rho = src.range(0.8, 1.3);
    cfg.cons[0].value = src.range(1, 120);
    cfg.cons[1] = .{ .q = sizing_types.q_VS, .op = sizing_types.op_le, .value = src.range(6, 20) };
    cfg.cons[2] = .{ .q = sizing_types.q_ee, .op = sizing_types.op_ge, .value = src.range(0, 2) };
    cfg.n_cons = @intCast(src.int(u32, 0, 3));
    cfg.n_airfoils = 2;
    cfg.airfoils[1] = .{ .clmax = src.range(0.8, 2.4), .cd0 = src.range(0.005, 0.03) };
    cfg.tip_same = @intFromBool(src.boolean());
    cfg.vars[sizing_types.v_airfoil] = .{ .lo = 0, .hi = 1, .kind = sizing_types.var_list };
    cfg.vars[sizing_types.v_airfoil_tip] = .{ .lo = 0, .hi = 1, .kind = sizing_types.var_list };
    cfg.n_layouts = 3; // nariz (1), asa (pares), propulsora (1, esteira)
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 4, .n_step = 2, .nacelle_CDS = src.range(0, 0.01), .mass_per_motor = src.range(0, 0.3) };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = src.range(0.7, 1) };
    cfg.vars[sizing_types.v_layout] = .{ .lo = 0, .hi = 2, .kind = sizing_types.var_list };
    var th: LinearThrust = .{ .T0_per_kg = src.range(5, 60), .Vz = src.range(10, 60) };
    var x: [sizing_types.n_vars]f64 = undefined;
    for (&x) |*v| v.* = src.mostly(-2, 6);
    inline for (kinds.all) |K| {
        const o = Chain(K, LinearThrust).eval(&cfg, &th, &x);
        // o vetor usado respeita os limites e os tipos
        for (0..sizing_types.n_vars) |i| {
            try testing.expect(o.x[i] >= @min(cfg.vars[i].lo, cfg.vars[i].hi) - 1e-12 and o.x[i] <= @max(cfg.vars[i].lo, cfg.vars[i].hi) + 1e-12);
        }
        try testing.expect(o.x[sizing_types.v_motors] == @round(o.x[sizing_types.v_motors]));
        if (cfg.tip_same != 0) try testing.expectEqual(o.x[sizing_types.v_airfoil], o.x[sizing_types.v_airfoil_tip]);
        // o número de motores respeita o arranjo (na asa: pares)
        const l = cfg.layouts[@intFromFloat(o.x[sizing_types.v_layout])];
        try testing.expect(o.x[sizing_types.v_motors] >= l.n_min and o.x[sizing_types.v_motors] <= l.n_max);
        if (l.n_step == 2) try testing.expect(@mod(o.x[sizing_types.v_motors], 2) == 0);
        try testing.expect(o.q[sizing_types.q_mtow] >= o.q[sizing_types.q_pv] - 1e-9 and o.violation >= 0);
        try testing.expect(std.math.isFinite(o.score));
        // no MTOW as restrições de massa cumprem; um pouco acima, alguma falha (se não bateu no teto)
        if (o.feasible == 1 and o.q[sizing_types.q_mtow] < cfg.m_max * 0.999) {
            var c2 = cfg;
            c2.vars[sizing_types.v_span] = .{ .lo = o.x[sizing_types.v_span], .hi = o.x[sizing_types.v_span] };
            c2.vars[sizing_types.v_area] = .{ .lo = o.x[sizing_types.v_area], .hi = o.x[sizing_types.v_area] };
            const md_ok = Chain(K, LinearThrust).eval(&c2, &th, &o.x);
            try testing.expectApproxEqRel(o.q[sizing_types.q_mtow], md_ok.q[sizing_types.q_mtow], 1e-9); // determinística
        }
    }
}

test "fuzz: cadeia inteira com tração mock, todos os tipos" {
    try fuzz.checkScaled({}, fuzzChain, .{}, 4);
}

test "curva sustentada como restrição: n ≥ 2 baixa o MTOW" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    const x = [_]f64{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 };
    const free = C.eval(&cfg, &th, &x);
    cfg.cons[1] = .{ .q = sizing_types.q_n_turn, .op = sizing_types.op_ge, .value = 2.0 };
    cfg.n_cons = 2;
    const turn = C.eval(&cfg, &th, &x);
    try testing.expect(turn.q[sizing_types.q_mtow] < free.q[sizing_types.q_mtow]);
    try testing.expect(turn.feasible == 1 and turn.q[sizing_types.q_n_turn] >= 2.0 - 1e-6);
    try testing.expect(std.math.isFinite(turn.q[sizing_types.q_ceiling]) or std.math.isNan(turn.q[sizing_types.q_ceiling]));
}

test "corda da raiz: retangular = S/b; afilada é maior" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    cfg.vars[sizing_types.v_taper] = .{ .lo = 1, .hi = 1 };
    const r = C.eval(&cfg, &th, &.{ 2.0, 0.8, 1.0, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4), r.q[sizing_types.q_c_root], 1e-12);
    cfg.vars[sizing_types.v_taper] = .{ .lo = 0.5, .hi = 0.5 };
    const t = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.5, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4 * 2 / 1.5), t.q[sizing_types.q_c_root], 1e-12);
}

test "arranjo: propulsora na esteira perde tração; naceles somam arrasto e massa" {
    var cfg = baseCfg();
    cfg.n_layouts = 3;
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 2, .n_step = 2, .nacelle_CDS = 0.004, .mass_per_motor = 0.15 };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = 0.85 };
    cfg.vars[sizing_types.v_motors] = .{ .lo = 1, .hi = 4, .kind = sizing_types.var_integer };
    cfg.vars[sizing_types.v_layout] = .{ .lo = 0, .hi = 2, .kind = sizing_types.var_list };
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    const nose = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    const push = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 2 });
    const wing = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 1 }); // pediu 1: na asa vira 2
    try testing.expectApproxEqRel(0.85 * nose.T[0], push.T[0], 1e-12);
    try testing.expect(push.q[sizing_types.q_mtow] < nose.q[sizing_types.q_mtow]);
    try testing.expectEqual(@as(f64, 2), wing.x[sizing_types.v_motors]);
    try testing.expectApproxEqAbs(nose.q[sizing_types.q_pv] + cfg.sets[0].mass + 2 * 0.15, wing.q[sizing_types.q_pv], 1e-9);
}

test "tração do núcleo: estática positiva e caindo com V" {
    const p = try testing.allocator.create(types.Params);
    defer testing.allocator.destroy(p);
    p.* = .{};
    var set: sizing_types.PropSet = .{};
    set.unit = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 2 };
    set.unit.J[1] = 0.68;
    set.unit.CT[0] = 0.09;
    set.unit.CP[0] = 0.03;
    set.unit.CP[1] = 0.006;
    var th: CoreThrust = .{ .p = p, .rho = 1.2 };
    const c = th.curve(&set, 2);
    try testing.expect(c.T[0] > 10 and c.T[10] < c.T[0]);
    const one = th.curve(&set, 1);
    try testing.expectApproxEqRel(c.T[0], 2 * one.T[0], 1e-12);
}
