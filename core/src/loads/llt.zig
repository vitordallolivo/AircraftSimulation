//! Linha sustentadora numérica (vórtices em ferradura) para a distribuição de carga ao longo da envergadura.
//!
//! Só para análise de cargas: a simulação (aero.zig) não chama este arquivo; o AeroDrive e as corridas ficam iguais.
//!
//! Fonte: Phillips, W. F. e Snyder, D. O., "Modern Adaptation of Prandtl's Classic Lifting-Line Theory",
//! Journal of Aircraft 37(4), 662–670, 2000 — vórtice em ferradura por painel, ligado a 1/4 da corda, pernas
//! livres ao longo do escoamento livre, ponto de controle no meio do segmento ligado, superfícies sem restrição de
//! enflechamento ou diedro, várias superfícies juntas. Biot–Savart de um segmento reto: Katz, J. e Plotkin, A.,
//! "Low-Speed Aerodynamics", 2ª ed., Cambridge, 2001, cap. 10 (segmento de vórtice reto) — números das equações a
//! conferir no PDF.
//!
//! Versão linear (seção c_l = a (α − α0), sem estol), como a teoria clássica de Prandtl (Anderson, "Fundamentals of
//! Aerodynamics", seção da linha sustentadora — a conferir no PDF). Por painel i, com Γ_i a circulação:
//!
//!     ρ |V_i| Γ_i = ½ ρ |V_i|² c_i η_i a_i (α_g,i − α0_i − (w_i · ez_i)/|V_i|),   w_i = Σ_j Γ_j w_ij
//!
//! w_ij: velocidade induzida no ponto de controle i pela ferradura j com Γ = 1; α_g: α do painel sem o downwash
//! empírico do núcleo (aqui quem dá o downwash na cauda são as pernas da asa) e com os comandos e modificadores.
//! Segmentos ligados: como na teoria de Prandtl, a linha sustentadora não induz velocidade nela mesma; entre painéis
//! da mesma superfície (mesmo grupo: as duas meias asas, por exemplo) entram só as pernas livres. Phillips e Snyder
//! somam também os segmentos ligados das outras ferraduras; numa quebra de diedro o segmento da outra meia asa passa a
//! milímetros do ponto de controle e dá um pico na raiz que depende da discretização (3° de diedro: +3 % na raiz).
//! Entre superfícies diferentes (asa → EH) entram as ferraduras inteiras.
//! a_i: inclinação 2D tirada do C_Lα 3D do núcleo invertendo Helmbold (o tradutor fez C_Lα = helmbold(a, AR)):
//!     C_Lα = a/(√(1+k²)+k), k = a/(πAR)   ⇒   a = C_Lα / √(1 − 2 C_Lα/(πAR))
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

const n_max = L.max_surfaces;
const far = 1e3; // comprimento das pernas (m): "infinito" para aviões deste tamanho

/// inclinação 2D a partir do C_Lα 3D (Helmbold invertido); sem solução (asa muito curta): 2π
pub fn sectionSlope(CLa: f64, AR: f64) f64 {
    if (AR <= 0) return CLa;
    const q = 1.0 - 2.0 * CLa / (fm.pi * AR);
    return if (q > 1e-6) CLa / @sqrt(q) else 2.0 * fm.pi;
}

/// velocidade induzida em P por um segmento de vórtice reto de A a B com Γ = 1 (Katz e Plotkin, cap. 10)
pub fn segment(P: V3, A: V3, B: V3) V3 {
    const r1 = P - A;
    const r2 = P - B;
    const c = vec.cross(r1, r2);
    const c2 = vec.dot(c, c);
    const n1 = vec.norm(r1);
    const n2 = vec.norm(r2);
    if (c2 < 1e-12 or n1 < 1e-9 or n2 < 1e-9) return vec.zero; // em cima da linha do vórtice
    const r0 = B - A;
    const k = vec.dot(r0, r1 / vec.splat(n1) - r2 / vec.splat(n2)) / (4.0 * fm.pi * c2);
    return c * vec.splat(k);
}

/// ferradura: perna de longe até A, A → B, B até longe (pernas ao longo de `u`, para onde o ar vai).
/// `bound` = false: só as pernas (painéis da mesma superfície; ver `apply`)
pub fn horseshoe(P: V3, A: V3, B: V3, u: V3, bound: bool) V3 {
    const Af = A + u * vec.splat(far);
    const Bf = B + u * vec.splat(far);
    const legs = segment(P, Af, A) + segment(P, B, Bf);
    return if (bound) legs + segment(P, A, B) else legs;
}

fn span(ps: *const T.PanelState, ez: V3) struct { A: V3, B: V3, d: V3 } {
    const ex = vec.v3(ps.ex);
    var d = vec.cross(ez, ex); // da esquerda para a direita (de baixo para cima nas verticais): Γ > 0 sustenta
    d = d / vec.splat(@max(vec.norm(d), 1e-12));
    const hw = 0.5 * ps.S / @max(ps.c, 1e-12);
    const r = vec.v3(ps.r);
    return .{ .A = r - d * vec.splat(hw), .B = r + d * vec.splat(hw), .d = d };
}

/// Resolve as circulações e reescreve os painéis do núcleo (`ps`, de `aero.computeTrace`) com a carga da linha
/// sustentadora: alpha (efetivo), CL (seção), CD, L, D, F e vind (+ a velocidade induzida pelas ferraduras).
/// `Vr`: velocidade do avião em relação ao ar (corpo); `d`: comandos (de, da, dr). Devolve a soma de Γ (teste).
pub fn apply(p: *const T.Params, Vr: V3, d: V3, ps: []T.PanelState) f64 {
    const n = @min(ps.len, n_max);
    const Va = vec.norm(Vr);
    if (Va < 1e-6 or n == 0) return 0;
    const u = -Vr / vec.splat(Va); // para onde o ar vai
    var A: [n_max][n_max]f64 = undefined;
    var rhs: [n_max]f64 = undefined;
    var used: [n_max]bool = undefined;
    var k_i: [n_max]f64 = undefined; // ½ c η a
    for (0..n) |i| {
        const s = &p.surf[i];
        const q = &ps[i];
        const ez = vec.v3(s.ez);
        const ex = vec.v3(s.ex);
        const v = vec.v3(q.v);
        const uu = vec.dot(v, ex);
        const ww = vec.dot(v, ez);
        const Vp = @sqrt(uu * uu + ww * ww);
        used[i] = q.group >= 0 and Vp > 1e-3 and q.S > 0;
        for (0..n) |j| A[i][j] = if (i == j) 1 else 0;
        rhs[i] = 0;
        if (!used[i]) continue;
        const ag = fm.atan2(ww, uu) + s.tau * vec.dot(vec.v3(s.mix), d);
        const a = sectionSlope(s.CLa, s.AR);
        const a0 = if (s.CLa != 0) -s.CL0 / s.CLa else 0;
        k_i[i] = 0.5 * q.c * s.eta * a;
        rhs[i] = k_i[i] * Vp * (ag - a0);
        const P = vec.v3(q.r);
        for (0..n) |j| {
            if (!used_geom(ps, j)) continue;
            const g = span(&ps[j], vec.v3(p.surf[j].ez));
            A[i][j] += k_i[i] * vec.dot(horseshoe(P, g.A, g.B, u, ps[j].group != q.group), ez);
        }
    }
    var G: [n_max]f64 = undefined;
    solve(n, &A, &rhs, &G);
    // carga de cada painel com as circulações
    var sum: f64 = 0;
    for (0..n) |i| {
        if (!used[i]) continue;
        const s = &p.surf[i];
        const q = &ps[i];
        const ez = vec.v3(s.ez);
        const ex = vec.v3(s.ex);
        const P = vec.v3(q.r);
        var w = vec.zero; // velocidade do ar induzida pelas ferraduras
        for (0..n) |j| {
            if (!used[j]) continue;
            const g = span(&ps[j], vec.v3(p.surf[j].ez));
            w += horseshoe(P, g.A, g.B, u, ps[j].group != q.group) * vec.splat(G[j]);
        }
        const v = vec.v3(q.v) - w; // velocidade do painel em relação ao ar, com a induzida
        const uu = vec.dot(v, ex);
        const ww = vec.dot(v, ez);
        const V2 = uu * uu + ww * ww;
        const Vp = @sqrt(V2);
        const al = fm.atan2(ww, uu) + s.tau * vec.dot(vec.v3(s.mix), d);
        const g = span(q, ez);
        const width = q.S / @max(q.c, 1e-12);
        const rho = p.env.rho;
        // Kutta–Joukowski no segmento ligado (ar = −v): F = ρ Γ (−v) × dl
        const Fl = vec.cross(-v, g.d) * vec.splat(rho * G[i] * width);
        const Lp = rho * Vp * G[i] * width;
        const qS = 0.5 * rho * V2 * s.eta * q.S;
        const drag_dir = -(ex * vec.splat(uu) + ez * vec.splat(ww)) / vec.splat(@max(Vp, 1e-12));
        const Dp = qS * s.CD0;
        const F = Fl + drag_dir * vec.splat(Dp);
        q.alpha = al;
        q.V = Vp;
        q.CL = if (qS > 0) Lp / qS else 0;
        q.L = Lp;
        q.D = vec.dot(F, drag_dir);
        q.CD = if (qS > 0) q.D / qS else 0;
        q.F = F;
        q.v = v;
        q.vind = vec.v3(q.vind) - w;
        sum += G[i];
    }
    return sum;
}

fn used_geom(ps: []const T.PanelState, j: usize) bool {
    return ps[j].group >= 0 and ps[j].S > 0 and ps[j].c > 0;
}

/// eliminação de Gauss com pivô parcial (n ≤ max_surfaces)
fn solve(n: usize, A: *[n_max][n_max]f64, b: *[n_max]f64, x: *[n_max]f64) void {
    for (0..n) |c| {
        var pv = c;
        for (c + 1..n) |r| {
            if (@abs(A[r][c]) > @abs(A[pv][c])) pv = r;
        }
        if (pv != c) {
            std.mem.swap([n_max]f64, &A[c], &A[pv]);
            std.mem.swap(f64, &b[c], &b[pv]);
        }
        const d = A[c][c];
        if (@abs(d) < 1e-15) continue;
        for (c + 1..n) |r| {
            const f = A[r][c] / d;
            if (f == 0) continue;
            for (c..n) |k| A[r][k] -= f * A[c][k];
            b[r] -= f * b[c];
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var s = b[i];
        for (i + 1..n) |k| s -= A[i][k] * x[k];
        x[i] = if (@abs(A[i][i]) < 1e-15) 0 else s / A[i][i];
    }
}

const testing = std.testing;

test "Helmbold invertido volta ao a do perfil" {
    const a = 2.0 * fm.pi;
    for ([_]f64{ 4, 6, 8, 12 }) |AR| {
        const k = a / (fm.pi * AR);
        const CLa = a / (@sqrt(1 + k * k) + k);
        try testing.expectApproxEqRel(a, sectionSlope(CLa, AR), 1e-12);
    }
}

test "segmento: vórtice infinito dá Γ/(2πh)" {
    const v = segment(.{ 0, 0, 1 }, .{ -1e5, 0, 0 }, .{ 1e5, 0, 0 });
    try testing.expectApproxEqRel(1.0 / (2.0 * fm.pi), vec.norm(v), 1e-6);
}

/// asa reta retangular em n faixas, corpo x à frente, z para baixo
fn rectWing(p: *T.Params, ps: []T.PanelState, n: usize, b: f64, c: f64, a: f64, V: f64, alpha: f64) void {
    const AR = b / c;
    const k = a / (fm.pi * AR);
    p.n_surf = @intCast(n);
    const w = b / @as(f64, @floatFromInt(n));
    for (0..n) |i| {
        const y = -0.5 * b + (@as(f64, @floatFromInt(i)) + 0.5) * w;
        p.surf[i] = .{ .S = w * c, .c = c, .AR = AR, .CLa = a / (@sqrt(1 + k * k) + k), .CL0 = 0, .CD0 = 0, .eta = 1,
            .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 }, .ez = .{ 0, 0, 1 } };
        ps[i] = .{ .r = .{ 0, y, 0 }, .S = w * c, .c = c, .group = 0, .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 },
            .v = .{ V * @cos(alpha), 0, V * @sin(alpha) } };
    }
}

test "asa retangular: carga cai na ponta, C_L perto de Helmbold e menor com alongamento menor" {
    var p = T.Params{};
    var ps: [40]T.PanelState = undefined;
    const al = 0.08;
    const V = 12.0;
    var CLs: [2]f64 = undefined;
    for ([_]f64{ 8, 4 }, 0..) |AR, m| {
        rectWing(&p, &ps, 40, AR * 0.25, 0.25, 2 * fm.pi, V, al);
        _ = apply(&p, .{ V * @cos(al), 0, V * @sin(al) }, vec.zero, ps[0..40]);
        var Lt: f64 = 0;
        for (ps[0..40]) |q| Lt += q.L;
        CLs[m] = Lt / (0.5 * p.env.rho * V * V * AR * 0.25 * 0.25);
        const tip = ps[0].L / ps[0].S;
        const root = ps[20].L / ps[20].S;
        try testing.expect(tip < 0.75 * root); // ponta descarregada
        try testing.expectApproxEqAbs(ps[0].L, ps[39].L, 1e-9 * root); // simétrica
        // Helmbold é uma aproximação da linha sustentadora: perto, não igual
        const k = 2 * fm.pi / (fm.pi * AR);
        try testing.expectApproxEqRel(2 * fm.pi / (@sqrt(1 + k * k) + k) * al, CLs[m], 0.06);
    }
    try testing.expect(CLs[1] < CLs[0]);
}

test "diedro: sem pico na raiz (a linha não induz nela mesma)" {
    var p = T.Params{};
    var ps: [40]T.PanelState = undefined;
    const al = 0.08;
    const V = 12.0;
    rectWing(&p, &ps, 40, 2.0, 0.25, 2 * fm.pi, V, al);
    const g = 3.0 * fm.pi / 180.0; // pontas para cima (z para baixo)
    for (0..40) |i| {
        const y = ps[i].r[1];
        const sd: f64 = if (y > 0) 1 else -1;
        ps[i].r[2] = -@abs(y) * @tan(g);
        p.surf[i].ez = .{ 0, sd * @sin(g), @cos(g) };
    }
    _ = apply(&p, .{ V * @cos(al), 0, V * @sin(al) }, vec.zero, ps[0..40]);
    // a carga cresce da ponta até a raiz sem saltar no meio
    try testing.expect(ps[19].L <= ps[18].L * 1.005);
}
