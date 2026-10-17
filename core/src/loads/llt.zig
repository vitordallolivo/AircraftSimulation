//! Linha sustentadora numérica (vórtices em ferradura) para a distribuição de carga ao longo da envergadura.
//!
//! Para as cargas e, com `Params.aero_model = 1` (physics/aeromodel.zig), para o voo. Com o padrão (0) a simulação
//! não chama este arquivo: o AeroDrive e as corridas ficam iguais.
//!
//! Fonte: Phillips, W. F. e Snyder, D. O., "Modern Adaptation of Prandtl's Classic Lifting-Line Theory",
//! Journal of Aircraft 37(4), 662–670, 2000 (também Hunsaker e Snyder, "A Lifting-Line Approach to Estimating
//! Propeller/Wing Interactions", eq. 6) — vórtice em ferradura por painel, com os nós nos pontos de 1/4 de corda das
//! bordas da faixa, pernas livres ao longo do escoamento livre, ponto de controle no meio do segmento ligado,
//! superfícies sem restrição de enflechamento ou diedro, várias superfícies juntas. Biot–Savart de um segmento reto: Katz, J. e Plotkin, A.,
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
//! Segmentos ligados: entram os de todas as ferraduras menos o do próprio painel (Phillips e Snyder). Com eles o
//! enflechamento tira sustentação; sem eles (e com a ferradura no centro da faixa) uma superfície enflechada ganhava
//! sustentação e o winglet carregava cada vez mais até a ponta. Limite: na quina da raiz (diedro, enflechamento) o
//! segmento da outra meia asa passa perto do ponto de controle e o valor ali depende da malha (singularidade; a
//! correção é a de Reid e Hunsaker, J. Aircraft 2020 — a conferir no PDF). Ver README.md.
//! Entre superfícies diferentes os vórtices têm núcleo de Scully (raio 0,1 c de quem solta; ver `core_frac`).
//! a_i: inclinação 2D tirada do C_Lα 3D do núcleo invertendo Helmbold (o tradutor fez C_Lα = helmbold(a, AR)):
//!     C_Lα = a/(√(1+k²)+k), k = a/(πAR)   ⇒   a = C_Lα / √(1 − 2 C_Lα/(πAR))
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const mods = @import("../modifiers/mod.zig");
const V3 = vec.V3;

const n_max = L.max_surfaces;
const far = 1e3; // comprimento das pernas (m): "infinito" para aviões deste tamanho
/// núcleo dos vórtices entre superfícies diferentes, em fração da corda de quem solta (Scully; Vatistas, Kozel e Mih,
/// "A simpler model for concentrated vortices", Experiments in Fluids 11, 1991, n = 1). Sem ele, a perna da raiz de
/// uma EV que encosta na EH passa a milímetros dos pontos de controle da EH e induz dezenas de m/s (1/h). Entre
/// 0,05 e 0,25 da corda o resultado quase não muda; dentro da mesma superfície não há núcleo (a queda na ponta depende
/// das pernas das faixas vizinhas, mais estreitas que qualquer núcleo dessa ordem)
const core_frac = 0.1;

/// inclinação 2D a partir do C_Lα 3D (Helmbold invertido); sem solução (asa muito curta): 2π
pub fn sectionSlope(CLa: f64, AR: f64) f64 {
    if (AR <= 0) return CLa;
    const q = 1.0 - 2.0 * CLa / (fm.pi * AR);
    return if (q > 1e-6) CLa / @sqrt(q) else 2.0 * fm.pi;
}

/// velocidade induzida em P por um segmento de vórtice reto de A a B com Γ = 1 (Katz e Plotkin, cap. 10)
pub fn segment(P: V3, A: V3, B: V3, rc: f64) V3 {
    const r1 = P - A;
    const r2 = P - B;
    const c = vec.cross(r1, r2);
    const r0 = B - A;
    // |r1 × r2| = h |r0| (h: distância à linha); núcleo de Scully: h² → h² + rc²
    const c2 = vec.dot(c, c) + rc * rc * vec.dot(r0, r0);
    const n1 = vec.norm(r1);
    const n2 = vec.norm(r2);
    if (c2 < 1e-12 or n1 < 1e-9 or n2 < 1e-9) return vec.zero; // em cima da linha do vórtice
    const k = vec.dot(r0, r1 / vec.splat(n1) - r2 / vec.splat(n2)) / (4.0 * fm.pi * c2);
    return c * vec.splat(k);
}

/// ferradura: perna de longe até A, A → B, B até longe (pernas ao longo de `u`, para onde o ar vai).
/// `bound` = false: só as pernas (painéis da mesma superfície; ver `apply`)
pub fn horseshoe(P: V3, A: V3, B: V3, u: V3, bound: bool, rc: f64) V3 {
    const Af = A + u * vec.splat(far);
    const Bf = B + u * vec.splat(far);
    const legs = segment(P, Af, A, rc) + segment(P, B, Bf, rc);
    return if (bound) legs + segment(P, A, B, rc) else legs;
}

fn span(ps: *const T.PanelState, ez: V3) struct { A: V3, B: V3, d: V3 } {
    const ex = vec.v3(ps.ex);
    var d = vec.cross(ez, ex); // da esquerda para a direita (de baixo para cima nas verticais): Γ > 0 sustenta
    d = d / vec.splat(@max(vec.norm(d), 1e-12));
    const hw = 0.5 * ps.S / @max(ps.c, 1e-12);
    const r = vec.v3(ps.r);
    return .{ .A = r - d * vec.splat(hw), .B = r + d * vec.splat(hw), .d = d };
}

/// os nós da ferradura do painel: os pontos de 1/4 de corda nas bordas da faixa (`qa`, `qb` do tradutor), como em
/// Phillips e Snyder (2000): ferraduras vizinhas dividem o nó e as pernas livres se cancelam onde Γ é igual, também
/// com enflechamento. A ordem segue `d` (Γ > 0 sustenta). Sem os nós (qa = qb = 0): o segmento perpendicular à
/// corda pelo centro (`span`), que só fecha as ferraduras sem enflechamento
fn nodes(s: *const T.Surface, ps: *const T.PanelState) Node {
    const g = span(ps, vec.v3(s.ez));
    const qa = vec.v3(s.qa);
    const qb = vec.v3(s.qb);
    const dl = qb - qa;
    if (vec.dot(dl, dl) < 1e-18) return .{ .A = g.A, .B = g.B, .d = g.d };
    return if (vec.dot(dl, g.d) >= 0) .{ .A = qa, .B = qb, .d = g.d } else .{ .A = qb, .B = qa, .d = g.d };
}

/// comprimento projetado no plano y-z do corpo (a coordenada de envergadura `s` de Goates e Hunsaker, eq. 4–6)
fn yz(v: V3) f64 {
    return @sqrt(v[1] * v[1] + v[2] * v[2]);
}

fn unit(v: V3) V3 {
    return v / vec.splat(@max(vec.norm(v), 1e-300));
}

/// Goates, C. D. e Hunsaker, D. F., "Practical Implementation of a General Numerical Lifting-Line Method", AIAA
/// SciTech 2021 (o método de Reid e Hunsaker, J. Aircraft 2020, na forma prática; implementado pelos autores no
/// MachUpX). O método de Phillips e Snyder não converge com a malha em derrapagem nem com enflechamento (G-H §II.A,
/// p. 4): as pernas saem inclinadas no plano da asa e a quina da raiz é singular. Duas correções:
///   - junta (eq. 3 e 17): cada perna sai do nó por um trecho de comprimento δ c_nó no plano da asa, perpendicular à
///     linha sustentadora (u_aΛ, eq. 12–15), e só depois segue o escoamento livre;
///   - linha sustentadora efetiva (eq. 7): para o ponto de controle i, os nós da mesma asa são misturados com a reta
///     tangente à linha em i, com peso exp(−σ (s − s_i)²); sem curvatura em i, a quina da raiz deixa de ser singular.
/// σ = (2 / (b_seg Δ cos Λ_i))², com s em metros e b_seg a semienvergadura (como no MachUpX, airplane.py; o artigo
/// escreve com s adimensional, eq. 8). δ = 0,15 e Δ: padrão do MachUpX 1,0 (o artigo usou 0,25 na validação, p. 19).
/// As asas são as cadeias de painéis do mesmo grupo que dividem nós; um ponto de controle vê as outras asas com a
/// geometria original (G-H §III.A).
const Wings = struct {
    g: [n_max]Node = undefined, // nós originais de cada painel (A à esquerda, B à direita)
    prev: [n_max]?usize = undefined, // painel com o nó B no nó A deste
    next: [n_max]?usize = undefined,
    wing: [n_max]usize = undefined, // índice da cadeia
    sA: [n_max]f64 = undefined, // s (m) dos nós, ao longo da cadeia
    sB: [n_max]f64 = undefined,
    cA: [n_max]f64 = undefined, // corda nos nós (média dos dois painéis que dividem o nó)
    cB: [n_max]f64 = undefined,
    bseg: [n_max]f64 = undefined, // semienvergadura da cadeia de cada painel (projetada em y-z)

    fn build(p: *const T.Params, ps: []const T.PanelState, n: usize) Wings {
        var w = Wings{};
        const tol = 1e-9;
        for (0..n) |j| {
            w.g[j] = nodes(&p.surf[j], &ps[j]);
            w.prev[j] = null;
            w.next[j] = null;
        }
        for (0..n) |j| {
            if (!used_geom(ps, j)) continue;
            for (0..n) |k| {
                if (k == j or !used_geom(ps, k) or ps[k].group != ps[j].group) continue;
                if (vec.norm(w.g[k].B - w.g[j].A) < tol) w.prev[j] = k;
                if (vec.norm(w.g[k].A - w.g[j].B) < tol) w.next[j] = k;
            }
        }
        var nw: usize = 0;
        for (0..n) |j| {
            if (!used_geom(ps, j) or w.prev[j] != null) continue;
            // começo de uma cadeia: anda até o fim somando s
            var total: f64 = 0;
            var two_sides = false;
            var k: ?usize = j;
            var guard: usize = 0;
            while (k) |c| : (guard += 1) {
                if (guard > n) break;
                w.wing[c] = nw;
                w.sA[c] = total;
                total += yz(w.g[c].B - w.g[c].A);
                w.sB[c] = total;
                if (ps[c].side != 0) two_sides = true;
                k = w.next[c];
            }
            const half = if (two_sides) 0.5 * total else total;
            k = j;
            guard = 0;
            while (k) |c| : (guard += 1) {
                if (guard > n) break;
                w.bseg[c] = half;
                w.cA[c] = if (w.prev[c]) |q| 0.5 * (ps[c].c + ps[q].c) else ps[c].c;
                w.cB[c] = if (w.next[c]) |q| 0.5 * (ps[c].c + ps[q].c) else ps[c].c;
                k = w.next[c];
            }
            nw += 1;
        }
        return w;
    }
};

const Node = struct { A: V3, B: V3, d: V3 };

/// direção da junta: perpendicular à tangente `t` no plano de `t` e de u_a (para trás, ao longo da corda), do lado
/// de u_a (G-H eq. 12–15)
fn jointDir(ua: V3, t: V3) V3 {
    return unit(ua - t * vec.splat(vec.dot(ua, t)));
}

/// velocidade induzida em P (Γ = 1) pela ferradura com junta: longe → jA → A → B → jB → longe; sem o segmento ligado
/// quando `bound` = false. Com jA = A e jB = B é a ferradura de Phillips e Snyder
fn jointed(P: V3, A: V3, B: V3, jA: V3, jB: V3, u: V3, bound: bool, rc: f64) V3 {
    const Af = jA + u * vec.splat(far);
    const Bf = jB + u * vec.splat(far);
    var v = segment(P, Af, jA, rc) + segment(P, jA, A, rc) + segment(P, B, jB, rc) + segment(P, jB, Bf, rc);
    if (bound) v += segment(P, A, B, rc);
    return v;
}

/// a linha de cada ferradura vista do ponto de controle i (Goates e Hunsaker): nós efetivos e juntas de todos os
/// painéis j; escreve em `infl[j]` a velocidade induzida em i por j com Γ = 1
fn ghInfluence(p: *const T.Params, ps: []const T.PanelState, n: usize, w: *const Wings, i: usize, u: V3, infl: []V3) void {
    var A: [n_max]V3 = undefined;
    var B: [n_max]V3 = undefined;
    var jA: [n_max]V3 = undefined;
    var jB: [n_max]V3 = undefined;
    ghRow(p, ps, n, w, i, &A, &B, &jA, &jB);
    const Pi = vec.v3(ps[i].r);
    for (0..n) |j| {
        infl[j] = vec.zero;
        if (!used_geom(ps, j)) continue;
        infl[j] = jointed(Pi, A[j], B[j], jA[j], jB[j], u, withBound(i, j), coreOf(ps, i, j));
    }
}

/// a geometria que o ponto de controle i vê (Goates e Hunsaker): os nós efetivos A, B e as juntas jA, jB de cada
/// painel j. Só depende da geometria: `prepare` guarda, `ghInfluence` recalcula quando não há cache
fn ghRow(p: *const T.Params, ps: []const T.PanelState, n: usize, w: *const Wings, i: usize, A: *[n_max]V3, B: *[n_max]V3, jA: *[n_max]V3, jB: *[n_max]V3) void {
    var ua: [n_max]V3 = undefined;
    const Pi = vec.v3(ps[i].r);
    const di = w.g[i].B - w.g[i].A;
    const D = di / vec.splat(@max(yz(di), 1e-12)); // d r / d s em i (s projetado em y-z)
    const cosL = yz(di) / @max(vec.norm(di), 1e-12);
    const si = 0.5 * (w.sA[i] + w.sB[i]);
    const den = w.bseg[i] * p.llt_blend * cosL;
    const sigma = if (p.llt_blend > 0 and den > 1e-12) (2.0 / den) * (2.0 / den) else 0.0;
    const uai = -vec.v3(ps[i].ex);
    for (0..n) |j| {
        A[j] = w.g[j].A;
        B[j] = w.g[j].B;
        ua[j] = -vec.v3(ps[j].ex);
        if (!used_geom(ps, j) or sigma == 0 or w.wing[j] != w.wing[i] or ps[j].group != ps[i].group) continue;
        const bA = @exp(-sigma * (w.sA[j] - si) * (w.sA[j] - si));
        const bB = @exp(-sigma * (w.sB[j] - si) * (w.sB[j] - si));
        A[j] = (Pi + D * vec.splat(w.sA[j] - si)) * vec.splat(bA) + A[j] * vec.splat(1 - bA);
        B[j] = (Pi + D * vec.splat(w.sB[j] - si)) * vec.splat(bB) + B[j] * vec.splat(1 - bB);
        const sc = 0.5 * (w.sA[j] + w.sB[j]) - si;
        const bc = @exp(-sigma * sc * sc);
        ua[j] = unit(uai * vec.splat(bc) + ua[j] * vec.splat(1 - bc));
    }
    for (0..n) |j| {
        jA[j] = A[j];
        jB[j] = B[j];
        if (!used_geom(ps, j)) continue;
        const dj = unit(B[j] - A[j]);
        const tA = if (w.prev[j]) |q| unit(dj + unit(B[q] - A[q])) else dj; // tangente nos nós (média dos vizinhos)
        const tB = if (w.next[j]) |q| unit(dj + unit(B[q] - A[q])) else dj;
        jA[j] = A[j] + jointDir(ua[j], tA) * vec.splat(p.llt_joint * w.cA[j]);
        jB[j] = B[j] + jointDir(ua[j], tB) * vec.splat(p.llt_joint * w.cB[j]);
    }
}

/// os painéis como `aero.computeTrace` os escreve, só com a geometria (para `prepare`, antes de qualquer escoamento)
fn geometryPanels(p: *const T.Params, n: usize, ps: []T.PanelState) void {
    for (0..n) |k| {
        const s = &p.surf[k];
        ps[k] = .{ .r = s.r, .S = s.S, .c = s.c, .group = s.group, .side = s.side, .ey = s.ey, .ex = s.ex };
    }
}

/// monta `Params.llt_cache` (chamado em `runner.configure`, depois de `aero.init`): de onde saem as pernas livres e
/// os segmentos fixos de cada par (i, j), para Phillips e Snyder ou Goates e Hunsaker conforme `llt_joint`,
/// `llt_blend`. Não muda nenhuma conta: `apply` com e sem o cache dá o mesmo resultado, bit a bit
pub fn prepare(p: *T.Params) void {
    const c = &p.llt_cache;
    c.ok = 0;
    const n: usize = @intCast(@min(@max(p.n_surf, 0), @as(i32, n_max)));
    var ps: [n_max]T.PanelState = undefined;
    geometryPanels(p, n, ps[0..n]);
    const gh = p.llt_joint > 0 or p.llt_blend > 0;
    const wings = if (gh) Wings.build(p, ps[0..n], n) else Wings{};
    for (0..n) |j| c.used[j] = @intFromBool(used_geom(ps[0..n], j));
    var A: [n_max]V3 = undefined;
    var B: [n_max]V3 = undefined;
    var jA: [n_max]V3 = undefined;
    var jB: [n_max]V3 = undefined;
    for (0..n) |i| {
        if (!used_geom(ps[0..n], i)) continue;
        if (gh) {
            ghRow(p, ps[0..n], n, &wings, i, &A, &B, &jA, &jB);
        } else {
            for (0..n) |j| {
                const g = nodes(&p.surf[j], &ps[j]);
                A[j] = g.A;
                B[j] = g.B;
                jA[j] = g.A;
                jB[j] = g.B;
            }
        }
        const P = vec.v3(ps[i].r);
        for (0..n) |j| {
            if (!used_geom(ps[0..n], j)) continue;
            const k = i * n_max + j;
            const rc = coreOf(ps[0..n], i, j);
            c.jA[k] = jA[j];
            c.jB[k] = jB[j];
            c.s2[k] = if (gh) segment(P, jA[j], A[j], rc) else vec.zero;
            c.s3[k] = if (gh) segment(P, B[j], jB[j], rc) else vec.zero;
            c.bound[k] = if (withBound(i, j)) segment(P, A[j], B[j], rc) else vec.zero;
        }
    }
    c.n = @intCast(n);
    c.gh = @intFromBool(gh);
    c.ok = 1;
}

/// a influência de j em i (Γ = 1) com o cache: só as duas pernas livres, somadas na mesma ordem de `horseshoe`
/// (Phillips e Snyder) ou de `jointed` (Goates e Hunsaker)
fn cachedInfluence(c: *const T.LltCache, P: V3, i: usize, j: usize, u: V3, rc: f64) V3 {
    const k = i * n_max + j;
    const jA = vec.v3(c.jA[k]);
    const jB = vec.v3(c.jB[k]);
    const Af = jA + u * vec.splat(far);
    const Bf = jB + u * vec.splat(far);
    const bound = withBound(i, j);
    if (c.gh != 0) {
        var v = segment(P, Af, jA, rc) + vec.v3(c.s2[k]) + vec.v3(c.s3[k]) + segment(P, jB, Bf, rc);
        if (bound) v += vec.v3(c.bound[k]);
        return v;
    }
    const legs = segment(P, Af, jA, rc) + segment(P, jB, Bf, rc);
    return if (bound) legs + vec.v3(c.bound[k]) else legs;
}

/// o cache serve para estes painéis: montado para a mesma configuração e com os mesmos painéis com geometria (um
/// painel sem escoamento no instante muda as cadeias de Goates e Hunsaker: aí a conta inteira)
fn cacheFits(p: *const T.Params, ps: []const T.PanelState, n: usize, gh: bool) bool {
    const c = &p.llt_cache;
    if (c.ok == 0 or c.n != @as(i32, @intCast(n)) or (c.gh != 0) != gh) return false;
    for (0..n) |j| {
        if ((c.used[j] != 0) != used_geom(ps, j)) return false;
    }
    return true;
}

/// a seção no plano normal à linha sustentadora (G-H §IV): eixos para a frente (−u_aΛ, eq. 12) e normal (−u_nΛ,
/// eq. 16), no lugar de `ex` e `ez`, e cos Λ_i (eq. 19). Sem enflechamento, são `ex`, `ez` e 1
const Section = struct { ex: V3, ez: V3, cosL: f64 };

fn sweptSection(s: *const T.Surface, ps: *const T.PanelState) Section {
    const g = nodes(s, ps);
    const dl = g.B - g.A;
    const us = unit(dl);
    const ua = jointDir(-vec.v3(ps.ex), us);
    const un = vec.cross(ua, us);
    return .{ .ex = -ua, .ez = -un, .cosL = yz(dl) / @max(vec.norm(dl), 1e-12) };
}

/// α do comando na seção enflechada: δ_fΛ = asin(cos Λ sen δ_f) (G-H eq. 23)
fn sweptControl(s: *const T.Surface, d: V3, cosL: f64) f64 {
    return s.tau * fm.asin(cosL * @sin(vec.dot(vec.v3(s.mix), d)));
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
    // Goates e Hunsaker (llt_joint, llt_blend > 0): a geometria muda com o ponto de controle; a influência fica
    // guardada para a segunda volta. Com os dois em 0, as contas são as de Phillips e Snyder, como sempre
    const gh = p.llt_joint > 0 or p.llt_blend > 0;
    var infl: [n_max][n_max]V3 = undefined;
    const cached = cacheFits(p, ps, n, gh); // a geometria fixa já montada (prepare): só as pernas livres
    const wings = if (gh and !cached) Wings.build(p, ps, n) else Wings{};
    for (0..n) |i| {
        const s = &p.surf[i];
        const q = &ps[i];
        // G-H: a seção no plano normal à linha (eq. 21, 27, 35); P-S: a seção na corda
        const sw = if (gh) sweptSection(s, q) else Section{ .ex = vec.v3(s.ex), .ez = vec.v3(s.ez), .cosL = 1 };
        const ez = sw.ez;
        const ex = sw.ex;
        const v = vec.v3(q.v);
        const uu = vec.dot(v, ex);
        const ww = vec.dot(v, ez);
        const Vp = @sqrt(uu * uu + ww * ww);
        used[i] = q.group >= 0 and Vp > 1e-3 and q.S > 0;
        for (0..n) |j| A[i][j] = if (i == j) 1 else 0;
        rhs[i] = 0;
        if (!used[i]) continue;
        const ag = fm.atan2(ww, uu) + (if (gh) sweptControl(s, d, sw.cosL) else s.tau * vec.dot(vec.v3(s.mix), d));
        const a = sectionSlope(s.CLa, s.AR);
        const a0 = (if (s.CLa != 0) -s.CL0 / s.CLa else 0) / sw.cosL;
        k_i[i] = 0.5 * q.c * sw.cosL * s.eta * a;
        rhs[i] = k_i[i] * Vp * (ag - a0);
        const P = vec.v3(q.r);
        if (cached) {
            for (0..n) |j| {
                infl[i][j] = vec.zero;
                if (!used_geom(ps, j)) continue;
                infl[i][j] = cachedInfluence(&p.llt_cache, P, i, j, u, coreOf(ps, i, j));
                A[i][j] += k_i[i] * vec.dot(infl[i][j], ez);
            }
            continue;
        }
        if (gh) {
            ghInfluence(p, ps, n, &wings, i, u, infl[i][0..n]);
            for (0..n) |j| {
                if (used_geom(ps, j)) A[i][j] += k_i[i] * vec.dot(infl[i][j], ez);
            }
            continue;
        }
        for (0..n) |j| {
            if (!used_geom(ps, j)) continue;
            const g = nodes(&p.surf[j], &ps[j]);
            A[i][j] += k_i[i] * vec.dot(horseshoe(P, g.A, g.B, u, withBound(i, j), coreOf(ps, i, j)), ez);
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
        const sw = if (gh) sweptSection(s, q) else Section{ .ex = vec.v3(s.ex), .ez = vec.v3(s.ez), .cosL = 1 };
        const ez = sw.ez;
        const ex = sw.ex;
        const P = vec.v3(q.r);
        var w = vec.zero; // velocidade do ar induzida pelas ferraduras
        for (0..n) |j| {
            if (!used[j]) continue;
            if (gh or cached) {
                w += infl[i][j] * vec.splat(G[j]);
                continue;
            }
            const g = nodes(&p.surf[j], &ps[j]);
            w += horseshoe(P, g.A, g.B, u, withBound(i, j), coreOf(ps, i, j)) * vec.splat(G[j]);
        }
        const v = vec.v3(q.v) - w; // velocidade do painel em relação ao ar, com a induzida
        const uu = vec.dot(v, ex);
        const ww = vec.dot(v, ez);
        const V2 = uu * uu + ww * ww;
        const Vp = @sqrt(V2);
        const al = fm.atan2(ww, uu) + (if (gh) sweptControl(s, d, sw.cosL) else s.tau * vec.dot(vec.v3(s.mix), d));
        const g = nodes(s, q);
        const rho = p.env.rho;
        // Kutta–Joukowski no segmento ligado (ar = −v): F = ρ Γ (−v) × dl, dl de nó a nó (com o enflechamento)
        const Fl = vec.cross(-v, g.B - g.A) * vec.splat(rho * G[i]);
        const Lp = std.math.sign(G[i]) * vec.norm(Fl);
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

/// as forças e momentos do avião (`aero.Out`, como `aero.computeEnv`) com a carga da linha sustentadora: a conta da
/// simulação (faixas, fuselagem, c_m das seções, modificadores, efeito solo a `h`) com as forças dos painéis trocadas
/// pelas de `apply`. É o modelo 1 do voo (`physics/aeromodel.zig`); o `ratioCL` e o `Fi` ficam os das faixas
pub fn compute(p: *const T.Params, Vr: V3, w: V3, rcg: V3, h: f64, d: V3, env: *const mods.Env) aero.Out {
    const n: usize = @intCast(@min(p.n_surf, @as(i32, n_max)));
    var ps: [n_max]T.PanelState = undefined;
    var o = aero.computeTrace(p, Vr, w, rcg, h, d, env, ps[0..n]);
    // tira as forças das faixas...
    for (ps[0..n]) |q| {
        if (q.group < 0) continue;
        const F = vec.v3(q.F);
        o.F -= F;
        o.M -= vec.cross(vec.v3(q.r) - rcg, F);
        o.Fg[@intCast(q.group)] -= F;
        o.Mg[@intCast(q.group)] -= vec.cross(vec.v3(q.r) - rcg, F);
    }
    _ = apply(p, Vr, d, ps[0..n]);
    // ... e põe as da linha sustentadora
    for (ps[0..n]) |q| {
        if (q.group < 0) continue;
        const F = vec.v3(q.F);
        o.F += F;
        o.M += vec.cross(vec.v3(q.r) - rcg, F);
        o.Fg[@intCast(q.group)] += F;
        o.Mg[@intCast(q.group)] += vec.cross(vec.v3(q.r) - rcg, F);
    }
    return o;
}

/// coeficientes do avião inteiro com a carga da linha sustentadora: a conta da simulação (`aero.computeTrace`: faixas,
/// fuselagem, c_m das seções, modificadores, efeito solo a `h`) com as forças dos painéis trocadas pelas de `apply`.
/// Mesmos argumentos e eixos de `aero.coeffsAt` (w em rad/s; momentos em `ref`). C_Di: NaN (as forças da linha
/// sustentadora não separam o induzido do de perfil)
pub fn coeffs(p: *const T.Params, V: f64, alpha: f64, beta: f64, w: V3, ref: V3, d: V3, h: f64, thrust: ?[2][]const f64) T.AeroCoeffs {
    const a = fm.sincos(alpha);
    const b = fm.sincos(beta);
    const Vr = V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    const env = if (thrust) |tq| mods.envFrom(p, Vr, w, tq[0], tq[1]) else mods.Env.none;
    const o = compute(p, Vr, w, ref, h, d, &env);
    const qS = 0.5 * p.env.rho * V * V * p.Sref;
    return .{
        .CL = (-o.F[2] * a.c + o.F[0] * a.s) / qS,
        .CD = -(o.F[0] * a.c * b.c + o.F[1] * b.s + o.F[2] * a.s * b.c) / qS,
        .CY = o.F[1] / qS,
        .Cl = o.M[0] / (qS * p.bref),
        .Cm = o.M[1] / (qS * p.cref),
        .Cn = o.M[2] / (qS * p.bref),
        .CL_wing = (-o.Fg[L.group_wing][2] * a.c + o.Fg[L.group_wing][0] * a.s) / qS,
        .CL_ht = (-o.Fg[L.group_htail][2] * a.c + o.Fg[L.group_htail][0] * a.s) / qS,
        .ratioCL = o.ratioCL,
        .CDi = std.math.nan(f64),
        .CN = -o.F[2] / qS,
    };
}

/// segmento ligado de j no ponto de controle de i: todos menos o do próprio painel (Phillips e Snyder 2000)
fn withBound(i: usize, j: usize) bool {
    return i != j;
}

/// núcleo de Scully só entre superfícies diferentes (ver `core_frac`)
fn coreOf(ps: []const T.PanelState, i: usize, j: usize) f64 {
    return if (ps[j].group != ps[i].group) core_frac * ps[j].c else 0;
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
    const v = segment(.{ 0, 0, 1 }, .{ -1e5, 0, 0 }, .{ 1e5, 0, 0 }, 0);
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
            .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 }, .ez = .{ 0, 0, 1 },
            .qa = .{ 0, y - 0.5 * w, 0 }, .qb = .{ 0, y + 0.5 * w, 0 } };
        ps[i] = .{ .r = .{ 0, y, 0 }, .S = w * c, .c = c, .group = 0, .side = if (y > 0) 1 else -1, .ex = .{ 1, 0, 0 },
            .ey = .{ 0, 1, 0 }, .v = .{ V * @cos(alpha), 0, V * @sin(alpha) } };
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

test "diedro: a raiz não salta mais que o VLM (1 %)" {
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
        p.surf[i].qa[2] = -@abs(p.surf[i].qa[1]) * @tan(g);
        p.surf[i].qb[2] = -@abs(p.surf[i].qb[1]) * @tan(g);
    }
    _ = apply(&p, .{ V * @cos(al), 0, V * @sin(al) }, vec.zero, ps[0..40]);
    // a carga cresce da ponta até a raiz sem saltar no meio
    // a carga não salta na raiz: no VLM do AeroSandbox (12 × 40 painéis por lado, asa plana AR 5) a faixa da raiz
    // fica 0,25 % acima da vizinha a 3° de diedro e 0,9 % a 10°; aqui, com os segmentos ligados da outra meia asa
    // (Phillips e Snyder), 0,7 %. A quina da raiz é singular na linha sustentadora (Reid e Hunsaker 2020)
    try testing.expect(ps[19].L <= ps[18].L * 1.01);
}

test "núcleo de Scully: finito na linha, metade do valor sem núcleo a h = rc" {
    const A = V3{ -1e5, 0, 0 };
    const B = V3{ 1e5, 0, 0 };
    const rc = 0.02;
    try testing.expectApproxEqAbs(@as(f64, 0), vec.norm(segment(.{ 0, 0, 1e-9 }, A, B, rc)), 1e-3);
    const free = vec.norm(segment(.{ 0, 0, rc }, A, B, 0));
    try testing.expectApproxEqRel(0.5 * free, vec.norm(segment(.{ 0, 0, rc }, A, B, rc)), 1e-6);
}

test "cauda em T: a perna da raiz da EV não explode na EH" {
    var p = T.Params{};
    var ps: [30]T.PanelState = undefined;
    const al = 0.05;
    const V = 12.0;
    rectWing(&p, &ps, 20, 0.8, 0.2, 2 * fm.pi, V, al); // EH em z = 0
    for (0..20) |i| ps[i].group = 1;
    // EV: 10 painéis de z = 0 até 0,3 m para cima, raiz em cima da EH, em x = 0, a 2 mm do ponto de controle de um
    // painel da EH (como nos aviões com a EV encostada na EH); com β para ter carga
    const h = 0.03;
    for (20..30) |i| {
        const k: f64 = @floatFromInt(i - 20);
        p.surf[i] = p.surf[0];
        p.surf[i].ez = .{ 0, 1, 0 };
        p.surf[i].S = h * 0.2;
        ps[i] = ps[0];
        ps[i].group = 2;
        ps[i].S = h * 0.2;
        ps[i].r = .{ 0, ps[10].r[1] + 0.002, -(k + 0.5) * h };
        ps[i].v = .{ V * @cos(al), V * 0.15, V * @sin(al) };
    }
    p.n_surf = 30;
    _ = apply(&p, .{ V * @cos(al), 0, V * @sin(al) }, vec.zero, ps[0..30]);
    // o painel da EH ao lado da raiz da EV não salta (sem núcleo: 5× os vizinhos)
    try testing.expect(ps[10].L < 1.5 * @max(ps[9].L, ps[11].L));
}

/// C_lβ (por rad) da asa retangular em n faixas a α, por diferença central em β = ±0,5°
fn rectClb(p: *T.Params, n: usize, alpha: f64) f64 {
    var ps: [n_max]T.PanelState = undefined;
    const V = 12.0;
    const b = 2.0;
    const c = 0.25;
    var Cl: [2]f64 = undefined;
    for ([_]f64{ 1, -1 }, 0..) |sg, m| {
        const be = sg * 0.5 * fm.pi / 180.0;
        rectWing(p, &ps, n, b, c, 2 * fm.pi, V, alpha);
        const Vr = V3{ V * @cos(alpha) * @cos(be), V * @sin(be), V * @sin(alpha) * @cos(be) };
        for (ps[0..n]) |*q| q.v = Vr;
        _ = apply(p, Vr, vec.zero, ps[0..n]);
        var Mx: f64 = 0;
        for (ps[0..n]) |q| Mx += q.r[1] * q.F[2] - q.r[2] * q.F[1];
        Cl[m] = Mx / (0.5 * p.env.rho * V * V * b * c * b);
    }
    return (Cl[0] - Cl[1]) / (2 * 0.5 * fm.pi / 180.0);
}

test "derrapagem: Phillips e Snyder não converge; Goates e Hunsaker converge e bate com o MachUpX" {
    // asa retangular AR 8 (b = 2 m, c = 0,25 m), a = 2π, α0 = 0, α = 0,08 rad. Referência: MachUpX (a implementação
    // de Goates e Hunsaker pelos autores, github.com/usuaero/MachUpX), 80 painéis por semiasa: C_lβ = 0,01524
    var p = T.Params{};
    const ps20 = rectClb(&p, 20, 0.08);
    const ps40 = rectClb(&p, 40, 0.08);
    try testing.expect(@abs(ps40 - ps20) > 0.1 * @abs(ps40)); // P-S: cresce com a malha (G-H §II.A)
    p.llt_joint = 0.15;
    p.llt_blend = 1.0;
    const gh20 = rectClb(&p, 20, 0.08);
    const gh40 = rectClb(&p, 40, 0.08);
    try testing.expectApproxEqRel(gh40, gh20, 0.03); // converge
    try testing.expectApproxEqRel(@as(f64, 0.01524), gh40, 0.05);
}

test "Goates e Hunsaker desligado por padrão (a linha sustentadora de sempre)" {
    const p = T.Params{};
    try testing.expect(p.llt_joint == 0 and p.llt_blend == 0);
}

test "coeffs: o avião com a carga da linha sustentadora (asa retangular AR 8)" {
    // a mesma asa de "asa retangular": C_L perto de Helmbold (6 %); sem β, C_l = C_n = 0; C_Di: NaN
    var p = T.Params{};
    var ps: [20]T.PanelState = undefined;
    const al = 0.08;
    const b = 2.0;
    const c = 0.25;
    rectWing(&p, &ps, 20, b, c, 2 * fm.pi, 12.0, al);
    for (0..20) |i| {
        p.surf[i].r = ps[i].r;
        p.surf[i].side = ps[i].side;
        p.surf[i].CLmax = 3.0;
    }
    p.Sref = b * c;
    p.cref = c;
    p.bref = b;
    aero.init(&p);
    const k = 2 * fm.pi / (fm.pi * b / c);
    const helm = 2 * fm.pi / (@sqrt(1 + k * k) + k) * al;
    const o = coeffs(&p, 12.0, al, 0, vec.zero, vec.zero, vec.zero, 50.0, null);
    try testing.expectApproxEqRel(helm, o.CL, 0.06);
    try testing.expectApproxEqAbs(@as(f64, 0), o.Cl, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), o.Cn, 1e-12);
    try testing.expect(std.math.isNan(o.CDi));
    // a simulação (faixas) na mesma asa: outro C_L, mesmo sinal e ordem
    const f = aero.coeffsAt(&p, 12.0, al, 0, vec.zero, vec.zero, vec.zero, 50.0, null);
    try testing.expect(o.CL != f.CL and @abs(o.CL - f.CL) < 0.1 * f.CL);
}

test "cache da geometria (prepare): o mesmo resultado, bit a bit, que a conta inteira" {
    // asa retangular com diedro, em derrapagem, nos dois métodos: Phillips e Snyder e Goates e Hunsaker
    inline for (.{ false, true }) |gh| {
        var p = T.Params{};
        var ps: [24]T.PanelState = undefined;
        const al = 0.08;
        const V = 12.0;
        rectWing(&p, &ps, 24, 2.0, 0.25, 2 * fm.pi, V, al);
        const g = 4.0 * fm.pi / 180.0;
        for (0..24) |i| {
            const y = ps[i].r[1];
            const sd: f64 = if (y > 0) 1 else -1;
            ps[i].r[2] = -@abs(y) * @tan(g);
            p.surf[i].ez = .{ 0, sd * @sin(g), @cos(g) };
            p.surf[i].qa[2] = -@abs(p.surf[i].qa[1]) * @tan(g);
            p.surf[i].qb[2] = -@abs(p.surf[i].qb[1]) * @tan(g);
            p.surf[i].r = ps[i].r;
            p.surf[i].side = ps[i].side;
        }
        if (gh) {
            p.llt_joint = 0.15;
            p.llt_blend = 1.0;
        }
        const be = 0.06;
        const Vr = V3{ V * @cos(al) * @cos(be), V * @sin(be), V * @sin(al) * @cos(be) };
        for (ps[0..24]) |*q| q.v = Vr;
        var a = ps;
        var b = ps;
        prepare(&p);
        try testing.expect(p.llt_cache.ok == 1);
        const ga = apply(&p, Vr, vec.zero, a[0..24]); // com o cache
        p.llt_cache.ok = 0;
        const gb = apply(&p, Vr, vec.zero, b[0..24]); // a conta inteira
        try testing.expectEqual(gb, ga);
        for (0..24) |i| {
            try testing.expectEqual(b[i].L, a[i].L);
            try testing.expectEqual(b[i].F, a[i].F);
        }
    }
}
