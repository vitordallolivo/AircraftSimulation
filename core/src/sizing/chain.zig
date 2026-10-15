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
const T = @import("../types.zig");
const prop = @import("../physics/propulsion.zig");
const S = @import("types.zig");
const st = @import("stages.zig");
const kinds = @import("kinds.zig");

pub fn checkThrust(comptime Th: type) void {
    if (!@hasDecl(Th, "curve")) @compileError("provedor de tração " ++ @typeName(Th) ++ " sem `curve`");
    _ = @as(fn (*Th, *const S.PropSet, f64) st.Curve, Th.curve);
}

/// tração do núcleo: ponto de equilíbrio do motor com acelerador cheio, em cada V da grade
pub const CoreThrust = struct {
    p: *T.Params, // só env.rho e prop[0] são usados
    rho: f64,

    pub fn curve(self: *CoreThrust, set: *const S.PropSet, n_motor: f64) st.Curve {
        self.p.env.rho = self.rho;
        self.p.n_prop = 1;
        self.p.prop[0] = set.unit;
        self.p.prop[0].tilt = 0;
        self.p.prop[0].toe = 0;
        self.p.prop[0].tilt_range = 0;
        prop.init(self.p);
        var c: st.Curve = .{ .V = st.Curve.grid(), .T = undefined };
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

    pub fn curve(self: *LinearThrust, set: *const S.PropSet, n_motor: f64) st.Curve {
        return st.linearCurve(self.T0_per_kg * set.mass * n_motor, self.Vz);
    }
};

/// x decodificado: dentro dos limites; inteiros e listas arredondados
pub fn decode(cfg: *const S.SizingCfg, x: []const f64, out: *[S.n_vars]f64) void {
    for (0..S.n_vars) |i| {
        const v = cfg.vars[i];
        const lo = @min(v.lo, v.hi);
        const hi = @max(v.lo, v.hi);
        const y = if (i < x.len and std.math.isFinite(x[i])) x[i] else lo;
        if (v.kind == S.var_continuous or lo == hi) {
            out[i] = std.math.clamp(y, lo, hi);
        } else { // inteiros e listas: inteiros dentro de [⌈lo⌉, ⌊hi⌋]
            const il = @ceil(lo);
            out[i] = std.math.clamp(@round(y), il, @max(@floor(hi), il));
        }
    }
    // listas: índice dentro do que existe
    out[S.v_airfoil] = std.math.clamp(out[S.v_airfoil], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[S.v_airfoil_tip] = if (cfg.tip_same != 0) out[S.v_airfoil] else std.math.clamp(out[S.v_airfoil_tip], 0, @as(f64, @floatFromInt(@max(cfg.n_airfoils, 1) - 1)));
    out[S.v_set] = std.math.clamp(out[S.v_set], 0, @as(f64, @floatFromInt(@max(cfg.n_sets, 1) - 1)));
    out[S.v_layout] = std.math.clamp(out[S.v_layout], 0, @as(f64, @floatFromInt(@max(cfg.n_layouts, 1) - 1)));
    out[S.v_motors] = motorsFor(cfg.layouts[@intFromFloat(out[S.v_layout])], out[S.v_motors], cfg.vars[S.v_motors]);
}

/// número de motores que o arranjo aceita, o mais perto do pedido (dentro dos limites da variável quando dá)
pub fn motorsFor(l: S.LayoutData, want: f64, v: S.VarSpec) f64 {
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
            geo: st.Geo,
            pol: st.Polar,
            curve: st.Curve,
            ms: st.Mass,
            tilt: f64,
        };

        /// grandezas que dependem da massa
        fn atMass(cfg: *const S.SizingCfg, md: *const Model, m: f64, q: *[S.n_q]f64, hover: *bool, env: ?*st.Env, with_ceiling: bool) void {
            const W = m * st.g0;
            const e = st.envelope(md.pol, &md.curve, W, md.geo.S, cfg.rho);
            const h = K.hover != .none and st.canHover(&md.curve, m, cfg.hover_margin);
            hover.* = h;
            q[S.q_VS] = e.Vs;
            q[S.q_Vmax] = e.Vmax;
            q[S.q_RC] = e.RC;
            q[S.q_TW] = e.TW;
            q[S.q_V_LD] = e.V_LD;
            q[S.q_LD] = e.LD;
            q[S.q_s_to] = if (h) 0.0 else if (K.hover == .required) std.math.inf(f64) else st.takeoffRun(md.pol, &md.curve, m, md.geo.S, cfg.rho, cfg.mu, md.tilt);
            const Vt = if (cfg.V_turn > 0) cfg.V_turn else 1.5 * e.Vs;
            q[S.q_n_turn] = st.sustainedN(md.pol, &md.curve, W, md.geo.S, cfg.rho, Vt);
            q[S.q_grad] = 100.0 * e.grad;
            q[S.q_s_land] = if (h) 0.0 else st.landingRun(md.pol, W, md.geo.S, cfg.rho, cfg.mu_brake);
            // o teto custa uma bisseção de envelopes: só quando alguém pede (restrição dele ou o resultado final)
            q[S.q_ceiling] = if (with_ceiling) st.ceiling(md.pol, &md.curve, W, md.geo.S, cfg.rho, cfg.roc_ceiling) else std.math.nan(f64);
            if (env) |p| p.* = e;
        }

        /// cumpre as restrições ativas que dependem da massa (e decola de algum jeito)
        fn massFeasible(cfg: *const S.SizingCfg, md: *const Model, m: f64) bool {
            var q: [S.n_q]f64 = undefined;
            var h = false;
            const n: usize = @intCast(std.math.clamp(cfg.n_cons, 0, S.max_cons));
            var need_ceiling = false;
            for (cfg.cons[0..n]) |c| need_ceiling = need_ceiling or c.q == S.q_ceiling;
            atMass(cfg, md, m, &q, &h, null, need_ceiling);
            if (!std.math.isFinite(q[S.q_s_to])) return false;
            for (cfg.cons[0..n]) |c| {
                const k: usize = @intCast(std.math.clamp(c.q, 0, S.n_q - 1));
                if (S.massDependent(k) and S.violation(c, q[k]) > 0) return false;
            }
            return true;
        }

        pub fn eval(cfg: *const S.SizingCfg, thrust: *Th, x: []const f64) S.SizingOut {
            var o: S.SizingOut = .{};
            decode(cfg, x, &o.x);
            const af = st.blendAirfoils(cfg.airfoils[@intFromFloat(o.x[S.v_airfoil])], cfg.airfoils[@intFromFloat(o.x[S.v_airfoil_tip])], o.x[S.v_taper]);
            const set = &cfg.sets[@intFromFloat(o.x[S.v_set])];
            const n_motor = o.x[S.v_motors];
            const lay = cfg.layouts[@intFromFloat(o.x[S.v_layout])];
            var md: Model = undefined;
            md.geo = st.geometry(K, o.x[S.v_span], o.x[S.v_area]);
            md.pol = st.polar(K, cfg, md.geo, af, n_motor * lay.nacelle_CDS);
            md.curve = thrust.curve(set, n_motor);
            for (&md.curve.T) |*t| t.* *= std.math.clamp(lay.thrust_factor, 0.0, 1.5); // instalação do arranjo
            md.ms = st.emptyMass(K, cfg, md.geo, set.mass + @max(lay.mass_per_motor, 0.0), n_motor);
            md.tilt = std.math.degreesToRadians(o.x[S.v_tilt]);
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
            var env: st.Env = undefined;
            var hover = false;
            atMass(cfg, &md, mtow, &o.q, &hover, &env, true);
            o.hover = @intFromBool(hover);
            o.CD0, o.K, o.CLmax, o.CLg = .{ md.pol.CD0, md.pol.K, md.pol.CLmax, md.pol.CLg };
            o.q[S.q_S] = md.geo.S;
            o.q[S.q_b] = md.geo.b;
            o.q[S.q_AR] = md.geo.AR;
            o.q[S.q_c_root] = 2.0 * md.geo.c / (1.0 + std.math.clamp(o.x[S.v_taper], 0.05, 1.0)); // c média → raiz
            o.q[S.q_n_surf] = @floatFromInt(K.surfaces());
            o.q[S.q_P] = set.P_max * n_motor;
            o.q[S.q_n_motor] = n_motor;
            o.q[S.q_mass] = mtow;
            o.q[S.q_mtow] = mtow;
            o.q[S.q_pv] = pv;
            o.q[S.q_cp] = mtow - pv;
            o.q[S.q_ee] = (mtow - pv) / pv;
            o.V = md.curve.V;
            o.T = md.curve.T;
            o.D = env.D;
            // violação: todas as restrições ativas no MTOW; sem decolar ou sem carga paga também conta
            var viol: f64 = if (ok_pv) 0.0 else 1.0;
            const n: usize = @intCast(std.math.clamp(cfg.n_cons, 0, S.max_cons));
            for (cfg.cons[0..n]) |c| {
                const k: usize = @intCast(std.math.clamp(c.q, 0, S.n_q - 1));
                viol += S.violation(c, o.q[k]);
            }
            if (!std.math.isFinite(viol)) viol = 1e3;
            o.violation = viol;
            o.feasible = @intFromBool(ok_pv and viol <= 1e-9);
            o.score = if (cfg.objective == S.obj_ee) o.q[S.q_ee] else mtow;
            return o;
        }
    };
}

// ------------------------------------------------------------------ testes (tração mock)
const testing = std.testing;
const fz = @import("../util/fuzz.zig");

fn baseCfg() S.SizingCfg {
    var c: S.SizingCfg = .{};
    c.vars[S.v_span] = .{ .lo = 2.0, .hi = 2.0 };
    c.vars[S.v_area] = .{ .lo = 0.8, .hi = 0.8 };
    c.vars[S.v_taper] = .{ .lo = 0.6, .hi = 0.6 };
    c.vars[S.v_motors] = .{ .lo = 1, .hi = 1, .kind = S.var_integer };
    c.sets[0].mass = 0.9;
    c.cons[0] = .{ .q = S.q_s_to, .op = S.op_le, .value = 40 };
    c.n_cons = 1;
    return c;
}

test "MTOW pela corrida: no MTOW a corrida bate a restrição" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const o = Chain(kinds.Monoplane, LinearThrust).eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    try testing.expect(o.feasible == 1);
    try testing.expectApproxEqRel(@as(f64, 40), o.q[S.q_s_to], 0.01);
    try testing.expectApproxEqAbs(o.q[S.q_mtow] - o.q[S.q_pv], o.q[S.q_cp], 1e-12);
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
    try testing.expect(vtol.feasible == 1 and vtol.hover == 1 and vtol.q[S.q_s_to] == 0);
    // pairado: MTOW = T0 / (margem g)
    try testing.expectApproxEqRel(75.0 / (cfg.hover_margin * st.g0), vtol.q[S.q_mtow], 1e-3);
}

test "biplano: mesma envergadura e área, menos arrasto induzido → mais subida" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const x = [_]f64{ 1.5, 0.9, 0.6, 0, 0, 1, 0, 0, 0 };
    const mono = Chain(kinds.Monoplane, LinearThrust).eval(&cfg, &th, &x);
    var c2 = cfg;
    c2.n_cons = 0;
    c2.m_max = mono.q[S.q_mtow]; // compara na mesma massa
    const a = Chain(kinds.Monoplane, LinearThrust).eval(&c2, &th, &x);
    const b = Chain(kinds.Biplane, LinearThrust).eval(&c2, &th, &x);
    try testing.expect(b.q[S.q_LD] > a.q[S.q_LD]);
}

fn fuzzChain(_: void, src: *fz.Src) !void {
    var cfg = baseCfg();
    cfg.vars[S.v_span] = .{ .lo = 0.5, .hi = 4 };
    cfg.vars[S.v_area] = .{ .lo = 0.1, .hi = 2 };
    cfg.vars[S.v_motors] = .{ .lo = 1, .hi = 4, .kind = S.var_integer };
    cfg.vars[S.v_tilt] = .{ .lo = 0, .hi = 12 };
    cfg.vars[S.v_set] = .{ .lo = 0, .hi = 1, .kind = S.var_list };
    cfg.n_sets = 2;
    cfg.sets[1].mass = src.range(0.1, 3);
    cfg.mu = src.range(0, 0.1);
    cfg.rho = src.range(0.8, 1.3);
    cfg.cons[0].value = src.range(1, 120);
    cfg.cons[1] = .{ .q = S.q_VS, .op = S.op_le, .value = src.range(6, 20) };
    cfg.cons[2] = .{ .q = S.q_ee, .op = S.op_ge, .value = src.range(0, 2) };
    cfg.n_cons = @intCast(src.int(u32, 0, 3));
    cfg.n_airfoils = 2;
    cfg.airfoils[1] = .{ .clmax = src.range(0.8, 2.4), .cd0 = src.range(0.005, 0.03) };
    cfg.tip_same = @intFromBool(src.boolean());
    cfg.vars[S.v_airfoil] = .{ .lo = 0, .hi = 1, .kind = S.var_list };
    cfg.vars[S.v_airfoil_tip] = .{ .lo = 0, .hi = 1, .kind = S.var_list };
    cfg.n_layouts = 3; // nariz (1), asa (pares), propulsora (1, esteira)
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 4, .n_step = 2, .nacelle_CDS = src.range(0, 0.01), .mass_per_motor = src.range(0, 0.3) };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = src.range(0.7, 1) };
    cfg.vars[S.v_layout] = .{ .lo = 0, .hi = 2, .kind = S.var_list };
    var th: LinearThrust = .{ .T0_per_kg = src.range(5, 60), .Vz = src.range(10, 60) };
    var x: [S.n_vars]f64 = undefined;
    for (&x) |*v| v.* = src.mostly(-2, 6);
    inline for (kinds.all) |K| {
        const o = Chain(K, LinearThrust).eval(&cfg, &th, &x);
        // o vetor usado respeita os limites e os tipos
        for (0..S.n_vars) |i| {
            try testing.expect(o.x[i] >= @min(cfg.vars[i].lo, cfg.vars[i].hi) - 1e-12 and o.x[i] <= @max(cfg.vars[i].lo, cfg.vars[i].hi) + 1e-12);
        }
        try testing.expect(o.x[S.v_motors] == @round(o.x[S.v_motors]));
        if (cfg.tip_same != 0) try testing.expectEqual(o.x[S.v_airfoil], o.x[S.v_airfoil_tip]);
        // o número de motores respeita o arranjo (na asa: pares)
        const l = cfg.layouts[@intFromFloat(o.x[S.v_layout])];
        try testing.expect(o.x[S.v_motors] >= l.n_min and o.x[S.v_motors] <= l.n_max);
        if (l.n_step == 2) try testing.expect(@mod(o.x[S.v_motors], 2) == 0);
        try testing.expect(o.q[S.q_mtow] >= o.q[S.q_pv] - 1e-9 and o.violation >= 0);
        try testing.expect(std.math.isFinite(o.score));
        // no MTOW as restrições de massa cumprem; um pouco acima, alguma falha (se não bateu no teto)
        if (o.feasible == 1 and o.q[S.q_mtow] < cfg.m_max * 0.999) {
            var c2 = cfg;
            c2.vars[S.v_span] = .{ .lo = o.x[S.v_span], .hi = o.x[S.v_span] };
            c2.vars[S.v_area] = .{ .lo = o.x[S.v_area], .hi = o.x[S.v_area] };
            const md_ok = Chain(K, LinearThrust).eval(&c2, &th, &o.x);
            try testing.expectApproxEqRel(o.q[S.q_mtow], md_ok.q[S.q_mtow], 1e-9); // determinística
        }
    }
}

test "fuzz: cadeia inteira com tração mock, todos os tipos" {
    try fz.checkScaled({}, fuzzChain, .{}, 4);
}

test "curva sustentada como restrição: n ≥ 2 baixa o MTOW" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    const x = [_]f64{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 };
    const free = C.eval(&cfg, &th, &x);
    cfg.cons[1] = .{ .q = S.q_n_turn, .op = S.op_ge, .value = 2.0 };
    cfg.n_cons = 2;
    const turn = C.eval(&cfg, &th, &x);
    try testing.expect(turn.q[S.q_mtow] < free.q[S.q_mtow]);
    try testing.expect(turn.feasible == 1 and turn.q[S.q_n_turn] >= 2.0 - 1e-6);
    try testing.expect(std.math.isFinite(turn.q[S.q_ceiling]) or std.math.isNan(turn.q[S.q_ceiling]));
}

test "corda da raiz: retangular = S/b; afilada é maior" {
    var cfg = baseCfg();
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    cfg.vars[S.v_taper] = .{ .lo = 1, .hi = 1 };
    const r = C.eval(&cfg, &th, &.{ 2.0, 0.8, 1.0, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4), r.q[S.q_c_root], 1e-12);
    cfg.vars[S.v_taper] = .{ .lo = 0.5, .hi = 0.5 };
    const t = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.5, 0, 0, 1, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.4 * 2 / 1.5), t.q[S.q_c_root], 1e-12);
}

test "arranjo: propulsora na esteira perde tração; naceles somam arrasto e massa" {
    var cfg = baseCfg();
    cfg.n_layouts = 3;
    cfg.layouts[0] = .{ .n_min = 1, .n_max = 1 };
    cfg.layouts[1] = .{ .n_min = 2, .n_max = 2, .n_step = 2, .nacelle_CDS = 0.004, .mass_per_motor = 0.15 };
    cfg.layouts[2] = .{ .n_min = 1, .n_max = 1, .thrust_factor = 0.85 };
    cfg.vars[S.v_motors] = .{ .lo = 1, .hi = 4, .kind = S.var_integer };
    cfg.vars[S.v_layout] = .{ .lo = 0, .hi = 2, .kind = S.var_list };
    var th: LinearThrust = .{};
    const C = Chain(kinds.Monoplane, LinearThrust);
    const nose = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 0 });
    const push = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 2 });
    const wing = C.eval(&cfg, &th, &.{ 2.0, 0.8, 0.6, 0, 0, 1, 0, 0, 1 }); // pediu 1: na asa vira 2
    try testing.expectApproxEqRel(0.85 * nose.T[0], push.T[0], 1e-12);
    try testing.expect(push.q[S.q_mtow] < nose.q[S.q_mtow]);
    try testing.expectEqual(@as(f64, 2), wing.x[S.v_motors]);
    try testing.expectApproxEqAbs(nose.q[S.q_pv] + cfg.sets[0].mass + 2 * 0.15, wing.q[S.q_pv], 1e-9);
}

test "tração do núcleo: estática positiva e caindo com V" {
    const p = try testing.allocator.create(T.Params);
    defer testing.allocator.destroy(p);
    p.* = .{};
    var set: S.PropSet = .{};
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
