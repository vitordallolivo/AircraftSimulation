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
//!
//! Versão não linear (`Params.llt_nonlinear = 1`, desligada por padrão): cada seção segue a sua curva c_l(α) com estol
//! (a reta acima misturada com a placa plana, como nas faixas: Beard e McLain, `aero.sigmaStall`), e o sistema
//!
//!     R_i(Γ) = Γ_i − ½ c_i η_i |V_i| c_l,i(α_i) = 0,   V_i = v_i − Σ_j Γ_j w_ij,   α_i = atan2(V_i·ez_i, V_i·ex_i) + comando
//!
//! é resolvido por Newton, partindo da solução linear (Phillips e Snyder 2000, versão não linear; Hunsaker e Snyder,
//! eq. 4 a 15 — números das equações a conferir no PDF). O c_l,max da seção sai do C_Lmax da faixa invertendo o fator
//! do tradutor, C_Lmax = 0,9 c_l,max (`aerosim/model/universal.py`; Raymer, "Aircraft Design: A Conceptual Approach",
//! eq. 12.15 — a conferir no PDF).
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const mods = @import("../modifiers/mod.zig");
const V3 = vec.V3;

const n_max = limits.max_surfaces;
const far = 1e3; // comprimento das pernas (m): "infinito" para aviões deste tamanho
/// núcleo dos vórtices entre superfícies diferentes, em fração da corda de quem solta (Scully; Vatistas, Kozel e Mih,
/// "A simpler model for concentrated vortices", Experiments in Fluids 11, 1991, n = 1). Sem ele, a perna da raiz de
/// uma EV que encosta na EH passa a milímetros dos pontos de controle da EH e induz dezenas de m/s (1/h). Entre
/// 0,05 e 0,25 da corda o resultado quase não muda; dentro da mesma superfície não há núcleo (a queda na ponta depende
/// das pernas das faixas vizinhas, mais estreitas que qualquer núcleo dessa ordem)
pub const core_frac = 0.1;

/// inclinação 2D a partir do C_Lα 3D (Helmbold invertido); sem solução (asa muito curta): 2π
pub fn sectionSlope(CLa: f64, AR: f64) f64 {
    if (AR <= 0) return CLa;
    const radicand = 1.0 - 2.0 * CLa / (fmath.pi * AR);
    return if (radicand > 1e-6) CLa / @sqrt(radicand) else 2.0 * fmath.pi;
}

/// C_Lmax = 0,9 c_l,max: o fator com que o tradutor passa do perfil para a faixa (`aerosim/model/universal.py`,
/// `_coeffs_from`; Raymer, eq. 12.15 — a conferir no PDF). A versão não linear volta ao c_l,max da seção com ele
pub const clmax_factor = 0.9;

/// a curva c_l(α) de uma seção: inclinação 2D, ângulo de sustentação nula e ângulo de estol da mistura com a placa
/// plana (`stall` ≤ 0: só a reta)
pub const Curve = struct { slope: f64, zero_lift: f64, stall: f64 };

/// c_l da seção em `alpha`: a reta a (α − α0) misturada com a placa plana depois do estol, com a mesma mistura das
/// faixas (Beard e McLain, `aero.sigmaStall`; `steepness` é o `Params.Mst`)
pub fn sectionLift(curve: Curve, alpha: f64, steepness: f64) f64 {
    const linear = curve.slope * (alpha - curve.zero_lift);
    if (curve.stall <= 0) return linear;
    const sigma = aero.sigmaStall(alpha, curve.stall, steepness);
    const sin_cos = fmath.sincos(alpha);
    return (1.0 - sigma) * linear + sigma * 2.0 * fmath.sgn(alpha) * sin_cos.s * sin_cos.s * sin_cos.c;
}

/// o maior c_l da curva em α de 0 a 0,9 rad: varredura de 0,01 rad e seção áurea em volta do melhor ponto
fn peakLift(curve: Curve, steepness: f64) f64 {
    var best: f64 = 0;
    var peak: f64 = -1e9;
    var alpha: f64 = 0.0;
    while (alpha < 0.9) : (alpha += 0.01) {
        const lift = sectionLift(curve, alpha, steepness);
        if (lift > peak) {
            peak = lift;
            best = alpha;
        }
    }
    const golden = 0.6180339887498949;
    var low = @max(best - 0.01, 0.0);
    var high = @min(best + 0.01, 0.9);
    for (0..40) |_| {
        const left = high - golden * (high - low);
        const right = low + golden * (high - low);
        if (sectionLift(curve, left, steepness) < sectionLift(curve, right, steepness)) low = left else high = right;
    }
    return @max(peak, sectionLift(curve, 0.5 * (low + high), steepness));
}

/// o ângulo de estol que faz o pico da curva igual a `clmax` (bisseção, como `aero.init` faz com as faixas);
/// `clmax` ≤ 0: sem estol (0)
pub fn stallAngle(slope: f64, zero_lift: f64, clmax: f64, steepness: f64) f64 {
    if (clmax <= 0) return 0;
    var low: f64 = 0.02;
    var high: f64 = 0.8;
    for (0..50) |_| {
        const stall = 0.5 * (low + high);
        if (peakLift(.{ .slope = slope, .zero_lift = zero_lift, .stall = stall }, steepness) > clmax) high = stall else low = stall;
    }
    return 0.5 * (low + high);
}

/// velocidade induzida em `point` por um segmento de vórtice reto de `start` a `end` com Γ = 1 (Katz e Plotkin, cap. 10)
pub fn segment(point: V3, start: V3, end: V3, rc: f64) V3 {
    const r1 = point - start;
    const r2 = point - end;
    const cross_r1r2 = vec.cross(r1, r2);
    const r0 = end - start;
    // |r1 × r2| = h |r0| (h: distância à linha); núcleo de Scully: h² → h² + rc²
    const c2 = vec.dot(cross_r1r2, cross_r1r2) + rc * rc * vec.dot(r0, r0);
    const n1 = vec.norm(r1);
    const n2 = vec.norm(r2);
    if (c2 < 1e-12 or n1 < 1e-9 or n2 < 1e-9) return vec.zero; // em cima da linha do vórtice
    const factor = vec.dot(r0, r1 / vec.splat(n1) - r2 / vec.splat(n2)) / (4.0 * fmath.pi * c2);
    return cross_r1r2 * vec.splat(factor);
}

/// ferradura: perna de longe até node_a, node_a → node_b, node_b até longe (pernas ao longo de `flow_dir`, para
/// onde o ar vai).
/// `bound` = false: só as pernas (painéis da mesma superfície; ver `apply`)
pub fn horseshoe(point: V3, node_a: V3, node_b: V3, flow_dir: V3, bound: bool, rc: f64) V3 {
    const far_a = node_a + flow_dir * vec.splat(far);
    const far_b = node_b + flow_dir * vec.splat(far);
    const legs = segment(point, far_a, node_a, rc) + segment(point, node_b, far_b, rc);
    return if (bound) legs + segment(point, node_a, node_b, rc) else legs;
}

/// o segmento perpendicular à corda pelo centro do painel (nós A e B) e a direção da envergadura
fn span(panel: *const types.PanelState, ez: V3) struct { A: V3, B: V3, d: V3 } {
    const ex = vec.v3(panel.ex);
    var span_dir = vec.cross(ez, ex); // da esquerda para a direita (de baixo para cima nas verticais): Γ > 0 sustenta
    span_dir = span_dir / vec.splat(@max(vec.norm(span_dir), 1e-12));
    const half_width = 0.5 * panel.S / @max(panel.c, 1e-12);
    const center = vec.v3(panel.r);
    return .{ .A = center - span_dir * vec.splat(half_width), .B = center + span_dir * vec.splat(half_width), .d = span_dir };
}

/// os nós da ferradura do painel: os pontos de 1/4 de corda nas bordas da faixa (`qa`, `qb` do tradutor), como em
/// Phillips e Snyder (2000): ferraduras vizinhas dividem o nó e as pernas livres se cancelam onde Γ é igual, também
/// com enflechamento. A ordem segue `d` (Γ > 0 sustenta). Sem os nós (qa = qb = 0): o segmento perpendicular à
/// corda pelo centro (`span`), que só fecha as ferraduras sem enflechamento
fn nodes(surface: *const types.Surface, panel: *const types.PanelState) Node {
    const centered = span(panel, vec.v3(surface.ez));
    const qa = vec.v3(surface.qa);
    const qb = vec.v3(surface.qb);
    const node_line = qb - qa;
    if (vec.dot(node_line, node_line) < 1e-18) return .{ .A = centered.A, .B = centered.B, .d = centered.d };
    return if (vec.dot(node_line, centered.d) >= 0) .{ .A = qa, .B = qb, .d = centered.d } else .{ .A = qb, .B = qa, .d = centered.d };
}

/// os nós da ferradura de um painel só com a geometria dele (para quem não tem o `PanelState`: modifiers/wingpair.zig)
pub fn surfaceNodes(surface: *const types.Surface) Node {
    const panel = types.PanelState{ .r = surface.r, .S = surface.S, .c = surface.c, .group = surface.group, .side = surface.side, .ey = surface.ey, .ex = surface.ex };
    return nodes(surface, &panel);
}

/// comprimento projetado no plano y-z do corpo (a coordenada de envergadura `s` de Goates e Hunsaker, eq. 4–6)
fn yz(vector: V3) f64 {
    return @sqrt(vector[1] * vector[1] + vector[2] * vector[2]);
}

/// o vetor dividido pelo módulo (vetor nulo continua nulo)
fn unit(vector: V3) V3 {
    return vector / vec.splat(@max(vec.norm(vector), 1e-300));
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

    /// as cadeias de painéis (asas) que dividem nós, com s, cordas e semienvergadura de cada uma
    fn build(params: *const types.Params, panels: []const types.PanelState, n_panels: usize) Wings {
        var wings = Wings{};
        const tol = 1e-9;
        for (0..n_panels) |j| {
            wings.g[j] = nodes(&params.surf[j], &panels[j]);
            wings.prev[j] = null;
            wings.next[j] = null;
        }
        for (0..n_panels) |j| {
            if (!used_geom(panels, j)) continue;
            for (0..n_panels) |cursor| {
                if (cursor == j or !used_geom(panels, cursor) or panels[cursor].group != panels[j].group) continue;
                if (vec.norm(wings.g[cursor].B - wings.g[j].A) < tol) wings.prev[j] = cursor;
                if (vec.norm(wings.g[cursor].A - wings.g[j].B) < tol) wings.next[j] = cursor;
            }
        }
        var n_wings: usize = 0;
        for (0..n_panels) |j| {
            if (!used_geom(panels, j) or wings.prev[j] != null) continue;
            // começo de uma cadeia: anda até o fim somando s
            var total: f64 = 0;
            var two_sides = false;
            var cursor: ?usize = j;
            var guard: usize = 0;
            while (cursor) |current| : (guard += 1) {
                if (guard > n_panels) break;
                wings.wing[current] = n_wings;
                wings.sA[current] = total;
                total += yz(wings.g[current].B - wings.g[current].A);
                wings.sB[current] = total;
                if (panels[current].side != 0) two_sides = true;
                cursor = wings.next[current];
            }
            const half = if (two_sides) 0.5 * total else total;
            cursor = j;
            guard = 0;
            while (cursor) |current| : (guard += 1) {
                if (guard > n_panels) break;
                wings.bseg[current] = half;
                wings.cA[current] = if (wings.prev[current]) |neighbor| 0.5 * (panels[current].c + panels[neighbor].c) else panels[current].c;
                wings.cB[current] = if (wings.next[current]) |neighbor| 0.5 * (panels[current].c + panels[neighbor].c) else panels[current].c;
                cursor = wings.next[current];
            }
            n_wings += 1;
        }
        return wings;
    }
};

/// os nós A e B da ferradura de um painel e a direção da envergadura `d`
pub const Node = struct { A: V3, B: V3, d: V3 };

/// direção da junta: perpendicular à tangente `tangent` no plano de `tangent` e de u_a (para trás, ao longo da corda), do lado
/// de u_a (G-H eq. 12–15)
fn jointDir(chord_aft: V3, tangent: V3) V3 {
    return unit(chord_aft - tangent * vec.splat(vec.dot(chord_aft, tangent)));
}

/// velocidade induzida em `point` (Γ = 1) pela ferradura com junta: longe → joint_a → node_a → node_b → joint_b → longe; sem o segmento ligado
/// quando `bound` = false. Com jA = A e jB = B é a ferradura de Phillips e Snyder
fn jointed(point: V3, node_a: V3, node_b: V3, joint_a: V3, joint_b: V3, flow_dir: V3, bound: bool, rc: f64) V3 {
    const far_a = joint_a + flow_dir * vec.splat(far);
    const far_b = joint_b + flow_dir * vec.splat(far);
    var velocity = segment(point, far_a, joint_a, rc) + segment(point, joint_a, node_a, rc) + segment(point, node_b, joint_b, rc) + segment(point, joint_b, far_b, rc);
    if (bound) velocity += segment(point, node_a, node_b, rc);
    return velocity;
}

/// a linha de cada ferradura vista do ponto de controle i (Goates e Hunsaker): nós efetivos e juntas de todos os
/// painéis j; escreve em `infl[j]` a velocidade induzida em i por j com Γ = 1
fn ghInfluence(params: *const types.Params, panels: []const types.PanelState, n_panels: usize, wings: *const Wings, i: usize, flow_dir: V3, infl: []V3) void {
    var node_a: [n_max]V3 = undefined;
    var node_b: [n_max]V3 = undefined;
    var joint_a: [n_max]V3 = undefined;
    var joint_b: [n_max]V3 = undefined;
    ghRow(params, panels, n_panels, wings, i, &node_a, &node_b, &joint_a, &joint_b);
    const control_point = vec.v3(panels[i].r);
    for (0..n_panels) |j| {
        infl[j] = vec.zero;
        if (!used_geom(panels, j)) continue;
        infl[j] = jointed(control_point, node_a[j], node_b[j], joint_a[j], joint_b[j], flow_dir, withBound(i, j), coreOf(panels, i, j));
    }
}

/// a geometria que o ponto de controle i vê (Goates e Hunsaker): os nós efetivos A, B e as juntas jA, jB de cada
/// painel j. Só depende da geometria: `prepare` guarda, `ghInfluence` recalcula quando não há cache
fn ghRow(params: *const types.Params, panels: []const types.PanelState, n_panels: usize, wings: *const Wings, i: usize, node_a: *[n_max]V3, node_b: *[n_max]V3, joint_a: *[n_max]V3, joint_b: *[n_max]V3) void {
    var ua: [n_max]V3 = undefined;
    const control_point = vec.v3(panels[i].r);
    const node_line = wings.g[i].B - wings.g[i].A;
    const tangent_rate = node_line / vec.splat(@max(yz(node_line), 1e-12)); // d r / d s em i (s projetado em y-z)
    const cosL = yz(node_line) / @max(vec.norm(node_line), 1e-12);
    const si = 0.5 * (wings.sA[i] + wings.sB[i]);
    const den = wings.bseg[i] * params.llt_blend * cosL;
    const sigma = if (params.llt_blend > 0 and den > 1e-12) (2.0 / den) * (2.0 / den) else 0.0;
    const uai = -vec.v3(panels[i].ex);
    for (0..n_panels) |j| {
        node_a[j] = wings.g[j].A;
        node_b[j] = wings.g[j].B;
        ua[j] = -vec.v3(panels[j].ex);
        if (!used_geom(panels, j) or sigma == 0 or wings.wing[j] != wings.wing[i] or panels[j].group != panels[i].group) continue;
        const blend_a = @exp(-sigma * (wings.sA[j] - si) * (wings.sA[j] - si));
        const blend_b = @exp(-sigma * (wings.sB[j] - si) * (wings.sB[j] - si));
        node_a[j] = (control_point + tangent_rate * vec.splat(wings.sA[j] - si)) * vec.splat(blend_a) + node_a[j] * vec.splat(1 - blend_a);
        node_b[j] = (control_point + tangent_rate * vec.splat(wings.sB[j] - si)) * vec.splat(blend_b) + node_b[j] * vec.splat(1 - blend_b);
        const s_center = 0.5 * (wings.sA[j] + wings.sB[j]) - si;
        const blend_center = @exp(-sigma * s_center * s_center);
        ua[j] = unit(uai * vec.splat(blend_center) + ua[j] * vec.splat(1 - blend_center));
    }
    for (0..n_panels) |j| {
        joint_a[j] = node_a[j];
        joint_b[j] = node_b[j];
        if (!used_geom(panels, j)) continue;
        const dir_j = unit(node_b[j] - node_a[j]);
        const tangent_a = if (wings.prev[j]) |neighbor| unit(dir_j + unit(node_b[neighbor] - node_a[neighbor])) else dir_j; // tangente nos nós (média dos vizinhos)
        const tangent_b = if (wings.next[j]) |neighbor| unit(dir_j + unit(node_b[neighbor] - node_a[neighbor])) else dir_j;
        joint_a[j] = node_a[j] + jointDir(ua[j], tangent_a) * vec.splat(params.llt_joint * wings.cA[j]);
        joint_b[j] = node_b[j] + jointDir(ua[j], tangent_b) * vec.splat(params.llt_joint * wings.cB[j]);
    }
}

/// os painéis como `aero.computeTrace` os escreve, só com a geometria (para `prepare`, antes de qualquer escoamento)
fn geometryPanels(params: *const types.Params, n_panels: usize, panels: []types.PanelState) void {
    for (0..n_panels) |k| {
        const surface = &params.surf[k];
        panels[k] = .{ .r = surface.r, .S = surface.S, .c = surface.c, .group = surface.group, .side = surface.side, .ey = surface.ey, .ex = surface.ex };
    }
}

/// monta `Params.llt_cache` (chamado em `runner.configure`, depois de `aero.init`): de onde saem as pernas livres e
/// os segmentos fixos de cada par (i, j), para Phillips e Snyder ou Goates e Hunsaker conforme `llt_joint`,
/// `llt_blend`. Não muda nenhuma conta: `apply` com e sem o cache dá o mesmo resultado, bit a bit
pub fn prepare(params: *types.Params) void {
    const cache = &params.llt_cache;
    cache.ok = 0;
    const n_panels: usize = @intCast(@min(@max(params.n_surf, 0), @as(i32, n_max)));
    var panels: [n_max]types.PanelState = undefined;
    geometryPanels(params, n_panels, panels[0..n_panels]);
    const gh = params.llt_joint > 0 or params.llt_blend > 0;
    const wings = if (gh) Wings.build(params, panels[0..n_panels], n_panels) else Wings{};
    for (0..n_panels) |j| cache.used[j] = @intFromBool(used_geom(panels[0..n_panels], j));
    var node_a: [n_max]V3 = undefined;
    var node_b: [n_max]V3 = undefined;
    var joint_a: [n_max]V3 = undefined;
    var joint_b: [n_max]V3 = undefined;
    for (0..n_panels) |i| {
        if (!used_geom(panels[0..n_panels], i)) continue;
        if (gh) {
            ghRow(params, panels[0..n_panels], n_panels, &wings, i, &node_a, &node_b, &joint_a, &joint_b);
        } else {
            for (0..n_panels) |j| {
                const node = nodes(&params.surf[j], &panels[j]);
                node_a[j] = node.A;
                node_b[j] = node.B;
                joint_a[j] = node.A;
                joint_b[j] = node.B;
            }
        }
        const point = vec.v3(panels[i].r);
        for (0..n_panels) |j| {
            if (!used_geom(panels[0..n_panels], j)) continue;
            const pair_index = i * n_max + j;
            const rc = coreOf(panels[0..n_panels], i, j);
            cache.jA[pair_index] = joint_a[j];
            cache.jB[pair_index] = joint_b[j];
            cache.s2[pair_index] = if (gh) segment(point, joint_a[j], node_a[j], rc) else vec.zero;
            cache.s3[pair_index] = if (gh) segment(point, node_b[j], joint_b[j], rc) else vec.zero;
            cache.bound[pair_index] = if (withBound(i, j)) segment(point, node_a[j], node_b[j], rc) else vec.zero;
        }
    }
    cache.nonlinear = 0;
    if (params.llt_nonlinear != 0) {
        for (0..n_panels) |i| {
            const cosL = if (gh) sweptSection(&params.surf[i], &panels[i]).cosL else 1.0;
            cache.stall[i] = panelStall(params, &params.surf[i], cosL);
        }
        cache.nonlinear = 1;
    }
    cache.n = @intCast(n_panels);
    cache.gh = @intFromBool(gh);
    cache.ok = 1;
}

/// a reta da seção do painel: inclinação 2D (Helmbold invertido) e α0 = −C_L0/C_Lα, dividido por cos Λ na seção
/// enflechada de Goates e Hunsaker (eq. 35; cos Λ = 1 em Phillips e Snyder)
fn sectionLine(surface: *const types.Surface, cosL: f64) struct { slope: f64, zero_lift: f64 } {
    return .{
        .slope = sectionSlope(surface.CLa, surface.AR),
        .zero_lift = (if (surface.CLa != 0) -surface.CL0 / surface.CLa else 0) / cosL,
    };
}

/// o ângulo de estol da seção do painel, com o c_l,max da seção (C_Lmax / `clmax_factor`)
fn panelStall(params: *const types.Params, surface: *const types.Surface, cosL: f64) f64 {
    const line = sectionLine(surface, cosL);
    return stallAngle(line.slope, line.zero_lift, surface.CLmax / clmax_factor, params.Mst);
}

/// a influência de j em i (Γ = 1) com o cache: só as duas pernas livres, somadas na mesma ordem de `horseshoe`
/// (Phillips e Snyder) ou de `jointed` (Goates e Hunsaker)
fn cachedInfluence(cache: *const types.LltCache, point: V3, i: usize, j: usize, flow_dir: V3, rc: f64) V3 {
    const pair_index = i * n_max + j;
    const joint_a = vec.v3(cache.jA[pair_index]);
    const joint_b = vec.v3(cache.jB[pair_index]);
    const far_a = joint_a + flow_dir * vec.splat(far);
    const far_b = joint_b + flow_dir * vec.splat(far);
    const bound = withBound(i, j);
    if (cache.gh != 0) {
        var velocity = segment(point, far_a, joint_a, rc) + vec.v3(cache.s2[pair_index]) + vec.v3(cache.s3[pair_index]) + segment(point, joint_b, far_b, rc);
        if (bound) velocity += vec.v3(cache.bound[pair_index]);
        return velocity;
    }
    const legs = segment(point, far_a, joint_a, rc) + segment(point, joint_b, far_b, rc);
    return if (bound) legs + vec.v3(cache.bound[pair_index]) else legs;
}

/// o cache serve para estes painéis: montado para a mesma configuração e com os mesmos painéis com geometria (um
/// painel sem escoamento no instante muda as cadeias de Goates e Hunsaker: aí a conta inteira)
fn cacheFits(params: *const types.Params, panels: []const types.PanelState, n_panels: usize, gh: bool) bool {
    const cache = &params.llt_cache;
    if (cache.ok == 0 or cache.n != @as(i32, @intCast(n_panels)) or (cache.gh != 0) != gh) return false;
    for (0..n_panels) |j| {
        if ((cache.used[j] != 0) != used_geom(panels, j)) return false;
    }
    return true;
}

/// a seção no plano normal à linha sustentadora (G-H §IV): eixos para a frente (−u_aΛ, eq. 12) e normal (−u_nΛ,
/// eq. 16), no lugar de `ex` e `ez`, e cos Λ_i (eq. 19). Sem enflechamento, são `ex`, `ez` e 1
const Section = struct { ex: V3, ez: V3, cosL: f64 };

/// a seção enflechada do painel (eixos e cos Λ) pelos nós da ferradura
fn sweptSection(surface: *const types.Surface, panel: *const types.PanelState) Section {
    const node = nodes(surface, panel);
    const node_line = node.B - node.A;
    const span_dir = unit(node_line);
    const chord_aft = jointDir(-vec.v3(panel.ex), span_dir);
    const normal = vec.cross(chord_aft, span_dir);
    return .{ .ex = -chord_aft, .ez = -normal, .cosL = yz(node_line) / @max(vec.norm(node_line), 1e-12) };
}

/// α do comando na seção enflechada: δ_fΛ = asin(cos Λ sen δ_f) (G-H eq. 23)
fn sweptControl(surface: *const types.Surface, deflections: V3, cosL: f64) f64 {
    return surface.tau * fmath.asin(cosL * @sin(vec.dot(vec.v3(surface.mix), deflections)));
}

/// Resolve as circulações e reescreve os painéis do núcleo (`ps`, de `aero.computeTrace`) com a carga da linha
/// sustentadora: alpha (efetivo), CL (seção), CD, L, D, F e vind (+ a velocidade induzida pelas ferraduras).
/// `Vr`: velocidade do avião em relação ao ar (corpo); `deflections`: comandos (de, da, dr). Devolve a soma de Γ (teste).
pub fn apply(params: *const types.Params, Vr: V3, deflections: V3, panels: []types.PanelState) f64 {
    const n_panels = @min(panels.len, n_max);
    const Va = vec.norm(Vr);
    if (Va < 1e-6 or n_panels == 0) return 0;
    const flow_dir = -Vr / vec.splat(Va); // para onde o ar vai
    var matrix: [n_max][n_max]f64 = undefined;
    var rhs: [n_max]f64 = undefined;
    var used: [n_max]bool = undefined;
    var k_i: [n_max]f64 = undefined; // ½ c η a
    // versão não linear (llt_nonlinear): o que o Newton precisa de cada painel
    const nonlinear = params.llt_nonlinear != 0;
    var sections: [n_max]Section = undefined;
    var controls: [n_max]f64 = undefined;
    var curves: [n_max]Curve = undefined;
    var half_chords: [n_max]f64 = undefined; // ½ c cos Λ η
    // Goates e Hunsaker (llt_joint, llt_blend > 0): a geometria muda com o ponto de controle; a influência fica
    // guardada para a segunda volta. Com os dois em 0, as contas são as de Phillips e Snyder, como sempre
    const gh = params.llt_joint > 0 or params.llt_blend > 0;
    var infl: [n_max][n_max]V3 = undefined;
    const cached = cacheFits(params, panels, n_panels, gh); // a geometria fixa já montada (prepare): só as pernas livres
    const wings = if (gh and !cached) Wings.build(params, panels, n_panels) else Wings{};
    for (0..n_panels) |i| {
        const surface = &params.surf[i];
        const panel = &panels[i];
        // G-H: a seção no plano normal à linha (eq. 21, 27, 35); P-S: a seção na corda
        const section = if (gh) sweptSection(surface, panel) else Section{ .ex = vec.v3(surface.ex), .ez = vec.v3(surface.ez), .cosL = 1 };
        const ez = section.ez;
        const ex = section.ex;
        const velocity = vec.v3(panel.v);
        const uu = vec.dot(velocity, ex);
        const ww = vec.dot(velocity, ez);
        const Vp = @sqrt(uu * uu + ww * ww);
        used[i] = panel.group >= 0 and Vp > 1e-3 and panel.S > 0;
        for (0..n_panels) |j| matrix[i][j] = if (i == j) 1 else 0;
        rhs[i] = 0;
        if (!used[i]) continue;
        const control = if (gh) sweptControl(surface, deflections, section.cosL) else surface.tau * vec.dot(vec.v3(surface.mix), deflections);
        const ag = fmath.atan2(ww, uu) + control;
        const line = sectionLine(surface, section.cosL);
        const slope = line.slope;
        const a0 = line.zero_lift;
        k_i[i] = 0.5 * panel.c * section.cosL * surface.eta * slope;
        rhs[i] = k_i[i] * Vp * (ag - a0);
        if (nonlinear) {
            sections[i] = section;
            controls[i] = control;
            half_chords[i] = 0.5 * panel.c * section.cosL * surface.eta;
            const stall = if (cached and params.llt_cache.nonlinear != 0) params.llt_cache.stall[i] else panelStall(params, surface, section.cosL);
            curves[i] = .{ .slope = slope, .zero_lift = a0, .stall = stall };
        }
        const point = vec.v3(panel.r);
        if (cached) {
            for (0..n_panels) |j| {
                infl[i][j] = vec.zero;
                if (!used_geom(panels, j)) continue;
                infl[i][j] = cachedInfluence(&params.llt_cache, point, i, j, flow_dir, coreOf(panels, i, j));
                matrix[i][j] += k_i[i] * vec.dot(infl[i][j], ez);
            }
            continue;
        }
        if (gh) {
            ghInfluence(params, panels, n_panels, &wings, i, flow_dir, infl[i][0..n_panels]);
            for (0..n_panels) |j| {
                if (used_geom(panels, j)) matrix[i][j] += k_i[i] * vec.dot(infl[i][j], ez);
            }
            continue;
        }
        for (0..n_panels) |j| {
            if (nonlinear) infl[i][j] = vec.zero;
            if (!used_geom(panels, j)) continue;
            const node = nodes(&params.surf[j], &panels[j]);
            const influence = horseshoe(point, node.A, node.B, flow_dir, withBound(i, j), coreOf(panels, i, j));
            if (nonlinear) infl[i][j] = influence;
            matrix[i][j] += k_i[i] * vec.dot(influence, ez);
        }
    }
    var gamma: [n_max]f64 = undefined;
    solve(n_panels, &matrix, &rhs, &gamma);
    if (nonlinear) {
        var velocities: [n_max]V3 = undefined;
        for (0..n_panels) |i| velocities[i] = vec.v3(panels[i].v);
        newton(.{ .n_panels = n_panels, .used = &used, .infl = &infl, .sections = &sections, .controls = &controls, .curves = &curves,
            .half_chords = &half_chords, .velocities = &velocities, .steepness = params.Mst }, &gamma);
    }
    // carga de cada painel com as circulações
    var sum: f64 = 0;
    for (0..n_panels) |i| {
        if (!used[i]) continue;
        const surface = &params.surf[i];
        const panel = &panels[i];
        const section = if (gh) sweptSection(surface, panel) else Section{ .ex = vec.v3(surface.ex), .ez = vec.v3(surface.ez), .cosL = 1 };
        const ez = section.ez;
        const ex = section.ex;
        const point = vec.v3(panel.r);
        var induced = vec.zero; // velocidade do ar induzida pelas ferraduras
        for (0..n_panels) |j| {
            if (!used[j]) continue;
            if (gh or cached or nonlinear) {
                induced += infl[i][j] * vec.splat(gamma[j]);
                continue;
            }
            const node = nodes(&params.surf[j], &panels[j]);
            induced += horseshoe(point, node.A, node.B, flow_dir, withBound(i, j), coreOf(panels, i, j)) * vec.splat(gamma[j]);
        }
        const velocity = vec.v3(panel.v) - induced; // velocidade do painel em relação ao ar, com a induzida
        const uu = vec.dot(velocity, ex);
        const ww = vec.dot(velocity, ez);
        const V2 = uu * uu + ww * ww;
        const Vp = @sqrt(V2);
        const al = fmath.atan2(ww, uu) + (if (gh) sweptControl(surface, deflections, section.cosL) else surface.tau * vec.dot(vec.v3(surface.mix), deflections));
        const node = nodes(surface, panel);
        const rho = params.env.rho;
        // Kutta–Joukowski no segmento ligado (ar = −v): F = ρ Γ (−v) × dl, dl de nó a nó (com o enflechamento)
        const Fl = vec.cross(-velocity, node.B - node.A) * vec.splat(rho * gamma[i]);
        const Lp = std.math.sign(gamma[i]) * vec.norm(Fl);
        const qS = 0.5 * rho * V2 * surface.eta * panel.S;
        const drag_dir = -(ex * vec.splat(uu) + ez * vec.splat(ww)) / vec.splat(@max(Vp, 1e-12));
        // não linear: depois do estol, o arrasto da placa plana das faixas (σ 1,2 sen²α, Beard e McLain)
        const stall_drag = if (nonlinear and curves[i].stall > 0) aero.sigmaStall(al, curves[i].stall, params.Mst) * 1.2 * @sin(al) * @sin(al) else 0.0;
        const Dp = if (nonlinear) qS * (surface.CD0 + stall_drag) else qS * surface.CD0;
        const force = Fl + drag_dir * vec.splat(Dp);
        panel.alpha = al;
        panel.V = Vp;
        panel.CL = if (qS > 0) Lp / qS else 0;
        panel.L = Lp;
        panel.D = vec.dot(force, drag_dir);
        panel.CD = if (qS > 0) panel.D / qS else 0;
        panel.F = force;
        panel.v = velocity;
        panel.vind = vec.v3(panel.vind) - induced;
        sum += gamma[i];
    }
    return sum;
}

/// as forças e momentos do avião (`aero.Out`, como `aero.computeEnv`) com a carga da linha sustentadora: a conta da
/// simulação (faixas, fuselagem, c_m das seções, modificadores, efeito solo a `height`) com as forças dos painéis
/// trocadas pelas de `apply`. É o modelo 1 do voo (`physics/aeromodel.zig`); o `ratioCL` e o `Fi` ficam os das faixas
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env) aero.Out {
    const n_panels: usize = @intCast(@min(params.n_surf, @as(i32, n_max)));
    var panels: [n_max]types.PanelState = undefined;
    var env_ll = env.*;
    env_ll.no_pair = true; // a interferência entre asas ligadas sai do sistema daqui, não do modifier das faixas
    var out = aero.computeTrace(params, Vr, body_rates, rcg, height, deflections, &env_ll, panels[0..n_panels]);
    // tira as forças das faixas...
    for (panels[0..n_panels]) |panel| {
        if (panel.group < 0) continue;
        const force = vec.v3(panel.F);
        out.F -= force;
        out.M -= vec.cross(vec.v3(panel.r) - rcg, force);
        out.Fg[@intCast(panel.group)] -= force;
        out.Mg[@intCast(panel.group)] -= vec.cross(vec.v3(panel.r) - rcg, force);
    }
    _ = apply(params, Vr, deflections, panels[0..n_panels]);
    // ... e põe as da linha sustentadora
    for (panels[0..n_panels]) |panel| {
        if (panel.group < 0) continue;
        const force = vec.v3(panel.F);
        out.F += force;
        out.M += vec.cross(vec.v3(panel.r) - rcg, force);
        out.Fg[@intCast(panel.group)] += force;
        out.Mg[@intCast(panel.group)] += vec.cross(vec.v3(panel.r) - rcg, force);
    }
    return out;
}

/// coeficientes do avião inteiro com a carga da linha sustentadora: a conta da simulação (`aero.computeTrace`: faixas,
/// fuselagem, c_m das seções, modificadores, efeito solo a `h`) com as forças dos painéis trocadas pelas de `apply`.
/// Mesmos argumentos e eixos de `aero.coeffsAt` (w em rad/s; momentos em `ref`). C_Di: NaN (as forças da linha
/// sustentadora não separam o induzido do de perfil)
pub fn coeffs(params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, body_rates: V3, ref: V3, deflections: V3, height: f64, thrust: ?[2][]const f64) types.AeroCoeffs {
    const sc_alpha = fmath.sincos(alpha);
    const sc_beta = fmath.sincos(beta);
    const Vr = V3{ airspeed * sc_alpha.c * sc_beta.c, airspeed * sc_beta.s, airspeed * sc_alpha.s * sc_beta.c };
    const env = if (thrust) |tq| mods.envFrom(params, Vr, body_rates, tq[0], tq[1]) else mods.Env.none;
    const out = compute(params, Vr, body_rates, ref, height, deflections, &env);
    const qS = 0.5 * params.env.rho * airspeed * airspeed * params.Sref;
    return .{
        .CL = (-out.F[2] * sc_alpha.c + out.F[0] * sc_alpha.s) / qS,
        .CD = -(out.F[0] * sc_alpha.c * sc_beta.c + out.F[1] * sc_beta.s + out.F[2] * sc_alpha.s * sc_beta.c) / qS,
        .CY = out.F[1] / qS,
        .Cl = out.M[0] / (qS * params.bref),
        .Cm = out.M[1] / (qS * params.cref),
        .Cn = out.M[2] / (qS * params.bref),
        .CL_wing = (-out.Fg[limits.group_wing][2] * sc_alpha.c + out.Fg[limits.group_wing][0] * sc_alpha.s) / qS,
        .CL_ht = (-out.Fg[limits.group_htail][2] * sc_alpha.c + out.Fg[limits.group_htail][0] * sc_alpha.s) / qS,
        .ratioCL = out.ratioCL,
        .CDi = std.math.nan(f64),
        .CN = -out.F[2] / qS,
    };
}

/// segmento ligado de j no ponto de controle de i: todos menos o do próprio painel (Phillips e Snyder 2000)
fn withBound(i: usize, j: usize) bool {
    return i != j;
}

/// núcleo de Scully só entre superfícies diferentes (ver `core_frac`)
fn coreOf(panels: []const types.PanelState, i: usize, j: usize) f64 {
    return if (panels[j].group != panels[i].group) core_frac * panels[j].c else 0;
}

/// verdadeiro se o painel j tem geometria (grupo, área e corda)
fn used_geom(panels: []const types.PanelState, j: usize) bool {
    return panels[j].group >= 0 and panels[j].S > 0 and panels[j].c > 0;
}

/// resolve matrix · solution = rhs por eliminação de Gauss com pivô parcial (size ≤ max_surfaces)
/// o que o Newton da versão não linear recebe de `apply`, por painel
const NewtonInput = struct {
    n_panels: usize,
    used: *const [n_max]bool,
    infl: *const [n_max][n_max]V3, // velocidade induzida em i pela ferradura j com Γ = 1
    sections: *const [n_max]Section,
    controls: *const [n_max]f64, // α do comando na seção
    curves: *const [n_max]Curve,
    half_chords: *const [n_max]f64, // ½ c cos Λ η
    velocities: *const [n_max]V3, // velocidade do painel em relação ao ar, sem a induzida pelas ferraduras
    steepness: f64,
};

/// o estado de uma seção com as circulações `gamma`: velocidade no plano da seção (componentes ao longo da corda e da
/// normal), módulo e α
const SectionFlow = struct { along: f64, normal: f64, speed: f64, alpha: f64 };

fn sectionFlow(input: NewtonInput, i: usize, gamma: *const [n_max]f64) SectionFlow {
    var velocity = input.velocities[i];
    for (0..input.n_panels) |j| {
        if (gamma[j] != 0) velocity -= input.infl[i][j] * vec.splat(gamma[j]);
    }
    const along = vec.dot(velocity, input.sections[i].ex);
    const normal = vec.dot(velocity, input.sections[i].ez);
    return .{ .along = along, .normal = normal, .speed = @sqrt(along * along + normal * normal), .alpha = fmath.atan2(normal, along) + input.controls[i] };
}

/// os resíduos R_i = Γ_i − ½ c_i η_i |V_i| c_l,i(α_i); devolve o maior |R_i|
fn residuals(input: NewtonInput, gamma: *const [n_max]f64, out: *[n_max]f64) f64 {
    var largest: f64 = 0;
    for (0..input.n_panels) |i| {
        out[i] = 0;
        if (!input.used[i]) continue;
        const flow = sectionFlow(input, i, gamma);
        out[i] = gamma[i] - input.half_chords[i] * flow.speed * sectionLift(input.curves[i], flow.alpha, input.steepness);
        largest = @max(largest, @abs(out[i]));
    }
    return largest;
}

/// Phillips e Snyder (2000), versão não linear: Newton em Γ a partir da solução linear (`gamma` entra com ela e sai
/// com a não linear). Jacobiano, com V_i = v_i − Σ Γ_j w_ij, u = V·ex e w = V·ez:
///   ∂R_i/∂Γ_j = δ_ij − ½ c_i η_i (c_l ∂|V_i|/∂Γ_j + |V_i| c_l' ∂α_i/∂Γ_j)
///   ∂|V_i|/∂Γ_j = −(u w_ij·ex + w w_ij·ez)/|V_i|,   ∂α_i/∂Γ_j = −(u w_ij·ez − w w_ij·ex)/|V_i|²
/// c_l' por diferença central. Passo amortecido: se o resíduo cresce, o passo cai pela metade (até 10 vezes); depois
/// do estol a solução pode não ser única, e o Newton fica com a mais perto da linear
fn newton(input: NewtonInput, gamma: *[n_max]f64) void {
    const n_panels = input.n_panels;
    var residual: [n_max]f64 = undefined;
    var largest = residuals(input, gamma, &residual);
    var scale: f64 = 1;
    for (0..n_panels) |i| scale = @max(scale, @abs(gamma[i]));
    var jacobian: [n_max][n_max]f64 = undefined;
    var step: [n_max]f64 = undefined;
    var negative: [n_max]f64 = undefined;
    for (0..50) |_| {
        if (largest <= 1e-12 * scale) return;
        for (0..n_panels) |i| {
            for (0..n_panels) |j| jacobian[i][j] = if (i == j) 1 else 0;
            negative[i] = -residual[i];
            if (!input.used[i]) continue;
            const flow = sectionFlow(input, i, gamma);
            const curve = input.curves[i];
            const lift = sectionLift(curve, flow.alpha, input.steepness);
            const delta = 1e-6;
            const lift_slope = (sectionLift(curve, flow.alpha + delta, input.steepness) - sectionLift(curve, flow.alpha - delta, input.steepness)) / (2 * delta);
            const speed = @max(flow.speed, 1e-12);
            for (0..n_panels) |j| {
                const along_rate = vec.dot(input.infl[i][j], input.sections[i].ex);
                const normal_rate = vec.dot(input.infl[i][j], input.sections[i].ez);
                const speed_rate = -(flow.along * along_rate + flow.normal * normal_rate) / speed;
                const alpha_rate = -(flow.along * normal_rate - flow.normal * along_rate) / (speed * speed);
                jacobian[i][j] -= input.half_chords[i] * (lift * speed_rate + speed * lift_slope * alpha_rate);
            }
        }
        solve(n_panels, &jacobian, &negative, &step);
        var trial: [n_max]f64 = undefined;
        var fraction: f64 = 1;
        var trial_residual: [n_max]f64 = undefined;
        var trial_largest: f64 = largest;
        for (0..11) |_| {
            for (0..n_panels) |i| trial[i] = gamma[i] + fraction * step[i];
            trial_largest = residuals(input, &trial, &trial_residual);
            if (trial_largest < largest) break;
            fraction *= 0.5;
        }
        if (trial_largest >= largest) return; // não melhora mais: fica com o último
        gamma.* = trial;
        residual = trial_residual;
        largest = trial_largest;
    }
}

fn solve(size: usize, matrix: *[n_max][n_max]f64, rhs: *[n_max]f64, solution: *[n_max]f64) void {
    for (0..size) |col| {
        var pivot = col;
        for (col + 1..size) |row| {
            if (@abs(matrix[row][col]) > @abs(matrix[pivot][col])) pivot = row;
        }
        if (pivot != col) {
            std.mem.swap([n_max]f64, &matrix[col], &matrix[pivot]);
            std.mem.swap(f64, &rhs[col], &rhs[pivot]);
        }
        const diagonal = matrix[col][col];
        if (@abs(diagonal) < 1e-15) continue;
        for (col + 1..size) |row| {
            const factor = matrix[row][col] / diagonal;
            if (factor == 0) continue;
            for (col..size) |k| matrix[row][k] -= factor * matrix[col][k];
            rhs[row] -= factor * rhs[col];
        }
    }
    var i = size;
    while (i > 0) {
        i -= 1;
        var sum = rhs[i];
        for (i + 1..size) |k| sum -= matrix[i][k] * solution[k];
        solution[i] = if (@abs(matrix[i][i]) < 1e-15) 0 else sum / matrix[i][i];
    }
}

const testing = std.testing;

test "Helmbold invertido volta ao a do perfil" {
    const slope = 2.0 * fmath.pi;
    for ([_]f64{ 4, 6, 8, 12 }) |AR| {
        const ratio = slope / (fmath.pi * AR);
        const CLa = slope / (@sqrt(1 + ratio * ratio) + ratio);
        try testing.expectApproxEqRel(slope, sectionSlope(CLa, AR), 1e-12);
    }
}

test "segmento: vórtice infinito dá Γ/(2πh)" {
    const velocity = segment(.{ 0, 0, 1 }, .{ -1e5, 0, 0 }, .{ 1e5, 0, 0 }, 0);
    try testing.expectApproxEqRel(1.0 / (2.0 * fmath.pi), vec.norm(velocity), 1e-6);
}

/// asa reta retangular em n_panels faixas, corpo x à frente, z para baixo
fn rectWing(params: *types.Params, panels: []types.PanelState, n_panels: usize, wing_span: f64, chord: f64, slope: f64, airspeed: f64, alpha: f64) void {
    const AR = wing_span / chord;
    const ratio = slope / (fmath.pi * AR);
    params.n_surf = @intCast(n_panels);
    const width = wing_span / @as(f64, @floatFromInt(n_panels));
    for (0..n_panels) |i| {
        const y_center = -0.5 * wing_span + (@as(f64, @floatFromInt(i)) + 0.5) * width;
        params.surf[i] = .{ .S = width * chord, .c = chord, .AR = AR, .CLa = slope / (@sqrt(1 + ratio * ratio) + ratio), .CL0 = 0, .CD0 = 0, .eta = 1,
            .ex = .{ 1, 0, 0 }, .ey = .{ 0, 1, 0 }, .ez = .{ 0, 0, 1 },
            .qa = .{ 0, y_center - 0.5 * width, 0 }, .qb = .{ 0, y_center + 0.5 * width, 0 } };
        panels[i] = .{ .r = .{ 0, y_center, 0 }, .S = width * chord, .c = chord, .group = 0, .side = if (y_center > 0) 1 else -1, .ex = .{ 1, 0, 0 },
            .ey = .{ 0, 1, 0 }, .v = .{ airspeed * @cos(alpha), 0, airspeed * @sin(alpha) } };
    }
}

test "asa retangular: carga cai na ponta, C_L perto de Helmbold e menor com alongamento menor" {
    var params = types.Params{};
    var panels: [40]types.PanelState = undefined;
    const al = 0.08;
    const airspeed = 12.0;
    var CLs: [2]f64 = undefined;
    for ([_]f64{ 8, 4 }, 0..) |AR, case| {
        rectWing(&params, &panels, 40, AR * 0.25, 0.25, 2 * fmath.pi, airspeed, al);
        _ = apply(&params, .{ airspeed * @cos(al), 0, airspeed * @sin(al) }, vec.zero, panels[0..40]);
        var Lt: f64 = 0;
        for (panels[0..40]) |panel| Lt += panel.L;
        CLs[case] = Lt / (0.5 * params.env.rho * airspeed * airspeed * AR * 0.25 * 0.25);
        const tip = panels[0].L / panels[0].S;
        const root = panels[20].L / panels[20].S;
        try testing.expect(tip < 0.75 * root); // ponta descarregada
        try testing.expectApproxEqAbs(panels[0].L, panels[39].L, 1e-9 * root); // simétrica
        // Helmbold é uma aproximação da linha sustentadora: perto, não igual
        const ratio = 2 * fmath.pi / (fmath.pi * AR);
        try testing.expectApproxEqRel(2 * fmath.pi / (@sqrt(1 + ratio * ratio) + ratio) * al, CLs[case], 0.06);
    }
    try testing.expect(CLs[1] < CLs[0]);
}

test "diedro: a raiz não salta mais que o VLM (1 %)" {
    var params = types.Params{};
    var panels: [40]types.PanelState = undefined;
    const al = 0.08;
    const airspeed = 12.0;
    rectWing(&params, &panels, 40, 2.0, 0.25, 2 * fmath.pi, airspeed, al);
    const dihedral = 3.0 * fmath.pi / 180.0; // pontas para cima (z para baixo)
    for (0..40) |i| {
        const y_center = panels[i].r[1];
        const sd: f64 = if (y_center > 0) 1 else -1;
        panels[i].r[2] = -@abs(y_center) * @tan(dihedral);
        params.surf[i].ez = .{ 0, sd * @sin(dihedral), @cos(dihedral) };
        params.surf[i].qa[2] = -@abs(params.surf[i].qa[1]) * @tan(dihedral);
        params.surf[i].qb[2] = -@abs(params.surf[i].qb[1]) * @tan(dihedral);
    }
    _ = apply(&params, .{ airspeed * @cos(al), 0, airspeed * @sin(al) }, vec.zero, panels[0..40]);
    // a carga cresce da ponta até a raiz sem saltar no meio
    // a carga não salta na raiz: no VLM do AeroSandbox (12 × 40 painéis por lado, asa plana AR 5) a faixa da raiz
    // fica 0,25 % acima da vizinha a 3° de diedro e 0,9 % a 10°; aqui, com os segmentos ligados da outra meia asa
    // (Phillips e Snyder), 0,7 %. A quina da raiz é singular na linha sustentadora (Reid e Hunsaker 2020)
    try testing.expect(panels[19].L <= panels[18].L * 1.01);
}

test "núcleo de Scully: finito na linha, metade do valor sem núcleo a h = rc" {
    const start = V3{ -1e5, 0, 0 };
    const end = V3{ 1e5, 0, 0 };
    const rc = 0.02;
    try testing.expectApproxEqAbs(@as(f64, 0), vec.norm(segment(.{ 0, 0, 1e-9 }, start, end, rc)), 1e-3);
    const free = vec.norm(segment(.{ 0, 0, rc }, start, end, 0));
    try testing.expectApproxEqRel(0.5 * free, vec.norm(segment(.{ 0, 0, rc }, start, end, rc)), 1e-6);
}

test "cauda em T: a perna da raiz da EV não explode na EH" {
    var params = types.Params{};
    var panels: [30]types.PanelState = undefined;
    const al = 0.05;
    const airspeed = 12.0;
    rectWing(&params, &panels, 20, 0.8, 0.2, 2 * fmath.pi, airspeed, al); // EH em z = 0
    for (0..20) |i| panels[i].group = 1;
    // EV: 10 painéis de z = 0 até 0,3 m para cima, raiz em cima da EH, em x = 0, a 2 mm do ponto de controle de um
    // painel da EH (como nos aviões com a EV encostada na EH); com β para ter carga
    const height_step = 0.03;
    for (20..30) |i| {
        const index: f64 = @floatFromInt(i - 20);
        params.surf[i] = params.surf[0];
        params.surf[i].ez = .{ 0, 1, 0 };
        params.surf[i].S = height_step * 0.2;
        panels[i] = panels[0];
        panels[i].group = 2;
        panels[i].S = height_step * 0.2;
        panels[i].r = .{ 0, panels[10].r[1] + 0.002, -(index + 0.5) * height_step };
        panels[i].v = .{ airspeed * @cos(al), airspeed * 0.15, airspeed * @sin(al) };
    }
    params.n_surf = 30;
    _ = apply(&params, .{ airspeed * @cos(al), 0, airspeed * @sin(al) }, vec.zero, panels[0..30]);
    // o painel da EH ao lado da raiz da EV não salta (sem núcleo: 5× os vizinhos)
    try testing.expect(panels[10].L < 1.5 * @max(panels[9].L, panels[11].L));
}

/// C_lβ (por rad) da asa retangular em n_panels faixas a α, por diferença central em β = ±0,5°
fn rectClb(params: *types.Params, n_panels: usize, alpha: f64) f64 {
    var panels: [n_max]types.PanelState = undefined;
    const airspeed = 12.0;
    const wing_span = 2.0;
    const chord = 0.25;
    var Cl: [2]f64 = undefined;
    for ([_]f64{ 1, -1 }, 0..) |sg, case| {
        const be = sg * 0.5 * fmath.pi / 180.0;
        rectWing(params, &panels, n_panels, wing_span, chord, 2 * fmath.pi, airspeed, alpha);
        const Vr = V3{ airspeed * @cos(alpha) * @cos(be), airspeed * @sin(be), airspeed * @sin(alpha) * @cos(be) };
        for (panels[0..n_panels]) |*panel| panel.v = Vr;
        _ = apply(params, Vr, vec.zero, panels[0..n_panels]);
        var Mx: f64 = 0;
        for (panels[0..n_panels]) |panel| Mx += panel.r[1] * panel.F[2] - panel.r[2] * panel.F[1];
        Cl[case] = Mx / (0.5 * params.env.rho * airspeed * airspeed * wing_span * chord * wing_span);
    }
    return (Cl[0] - Cl[1]) / (2 * 0.5 * fmath.pi / 180.0);
}

test "derrapagem: Phillips e Snyder não converge; Goates e Hunsaker converge e bate com o MachUpX" {
    // asa retangular AR 8 (b = 2 m, c = 0,25 m), a = 2π, α0 = 0, α = 0,08 rad. Referência: MachUpX (a implementação
    // de Goates e Hunsaker pelos autores, github.com/usuaero/MachUpX), 80 painéis por semiasa: C_lβ = 0,01524
    var params = types.Params{};
    const ps20 = rectClb(&params, 20, 0.08);
    const ps40 = rectClb(&params, 40, 0.08);
    try testing.expect(@abs(ps40 - ps20) > 0.1 * @abs(ps40)); // P-S: cresce com a malha (G-H §II.A)
    params.llt_joint = 0.15;
    params.llt_blend = 1.0;
    const gh20 = rectClb(&params, 20, 0.08);
    const gh40 = rectClb(&params, 40, 0.08);
    try testing.expectApproxEqRel(gh40, gh20, 0.03); // converge
    try testing.expectApproxEqRel(@as(f64, 0.01524), gh40, 0.05);
}

test "Goates e Hunsaker desligado por padrão (a linha sustentadora de sempre)" {
    const params = types.Params{};
    try testing.expect(params.llt_joint == 0 and params.llt_blend == 0);
}

test "coeffs: o avião com a carga da linha sustentadora (asa retangular AR 8)" {
    // a mesma asa de "asa retangular": C_L perto de Helmbold (6 %); sem β, C_l = C_n = 0; C_Di: NaN
    var params = types.Params{};
    var panels: [20]types.PanelState = undefined;
    const al = 0.08;
    const wing_span = 2.0;
    const chord = 0.25;
    rectWing(&params, &panels, 20, wing_span, chord, 2 * fmath.pi, 12.0, al);
    for (0..20) |i| {
        params.surf[i].r = panels[i].r;
        params.surf[i].side = panels[i].side;
        params.surf[i].CLmax = 3.0;
    }
    params.Sref = wing_span * chord;
    params.cref = chord;
    params.bref = wing_span;
    aero.init(&params);
    const ratio = 2 * fmath.pi / (fmath.pi * wing_span / chord);
    const helm = 2 * fmath.pi / (@sqrt(1 + ratio * ratio) + ratio) * al;
    const out = coeffs(&params, 12.0, al, 0, vec.zero, vec.zero, vec.zero, 50.0, null);
    try testing.expectApproxEqRel(helm, out.CL, 0.06);
    try testing.expectApproxEqAbs(@as(f64, 0), out.Cl, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), out.Cn, 1e-12);
    try testing.expect(std.math.isNan(out.CDi));
    // a simulação (faixas) na mesma asa: outro C_L, mesmo sinal e ordem
    const strips = aero.coeffsAt(&params, 12.0, al, 0, vec.zero, vec.zero, vec.zero, 50.0, null);
    try testing.expect(out.CL != strips.CL and @abs(out.CL - strips.CL) < 0.1 * strips.CL);
}

test "cache da geometria (prepare): o mesmo resultado, bit a bit, que a conta inteira" {
    // asa retangular com diedro, em derrapagem, nos dois métodos: Phillips e Snyder e Goates e Hunsaker
    inline for (.{ false, true }) |gh| {
        var params = types.Params{};
        var panels: [24]types.PanelState = undefined;
        const al = 0.08;
        const airspeed = 12.0;
        rectWing(&params, &panels, 24, 2.0, 0.25, 2 * fmath.pi, airspeed, al);
        const dihedral = 4.0 * fmath.pi / 180.0;
        for (0..24) |i| {
            const y_center = panels[i].r[1];
            const sd: f64 = if (y_center > 0) 1 else -1;
            panels[i].r[2] = -@abs(y_center) * @tan(dihedral);
            params.surf[i].ez = .{ 0, sd * @sin(dihedral), @cos(dihedral) };
            params.surf[i].qa[2] = -@abs(params.surf[i].qa[1]) * @tan(dihedral);
            params.surf[i].qb[2] = -@abs(params.surf[i].qb[1]) * @tan(dihedral);
            params.surf[i].r = panels[i].r;
            params.surf[i].side = panels[i].side;
        }
        if (gh) {
            params.llt_joint = 0.15;
            params.llt_blend = 1.0;
        }
        const be = 0.06;
        const Vr = V3{ airspeed * @cos(al) * @cos(be), airspeed * @sin(be), airspeed * @sin(al) * @cos(be) };
        for (panels[0..24]) |*panel| panel.v = Vr;
        var cached = panels;
        var full = panels;
        prepare(&params);
        try testing.expect(params.llt_cache.ok == 1);
        const ga = apply(&params, Vr, vec.zero, cached[0..24]); // com o cache
        params.llt_cache.ok = 0;
        const gb = apply(&params, Vr, vec.zero, full[0..24]); // a conta inteira
        try testing.expectEqual(gb, ga);
        for (0..24) |i| {
            try testing.expectEqual(full[i].L, cached[i].L);
            try testing.expectEqual(full[i].F, cached[i].F);
        }
    }
}

/// sustentação total e C_L da asa retangular de `rectWing` (n_panels faixas) no ângulo `alpha`
fn rectLift(params: *types.Params, panels: []types.PanelState, wing_span: f64, chord: f64, airspeed: f64, alpha: f64) f64 {
    rectWing(params, panels, panels.len, wing_span, chord, 2 * fmath.pi, airspeed, alpha);
    _ = apply(params, .{ airspeed * @cos(alpha), 0, airspeed * @sin(alpha) }, vec.zero, panels);
    var total: f64 = 0;
    for (panels) |panel| total += panel.L;
    return total / (0.5 * params.env.rho * airspeed * airspeed * wing_span * chord);
}

test "não linear desligado por padrão" {
    const params = types.Params{};
    try testing.expect(params.llt_nonlinear == 0);
}

test "curva da seção: reta antes do estol e pico igual ao c_l,max pedido" {
    const slope = 2.0 * fmath.pi;
    const zero_lift = -0.04;
    const clmax = 1.4;
    const stall = stallAngle(slope, zero_lift, clmax, 50);
    const curve = Curve{ .slope = slope, .zero_lift = zero_lift, .stall = stall };
    try testing.expectApproxEqRel(clmax, peakLift(curve, 50), 1e-6);
    try testing.expectApproxEqRel(slope * (0.05 - zero_lift), sectionLift(curve, 0.05, 50), 1e-6);
    try testing.expect(sectionLift(curve, 0.6, 50) < 0.8 * clmax); // depois do estol, cai
    try testing.expectEqual(@as(f64, 0), stallAngle(slope, zero_lift, 0, 50)); // sem c_l,max: sem estol
}

test "não linear: em α pequeno fica com a linear; perto do estol o C_L para abaixo do c_l,max da seção" {
    var params = types.Params{};
    var panels: [32]types.PanelState = undefined;
    const wing_span = 2.0;
    const chord = 0.25;
    const airspeed = 12.0;
    const linear_small = rectLift(&params, &panels, wing_span, chord, airspeed, 0.04);
    params.llt_nonlinear = 1;
    const nonlinear_small = rectLift(&params, &panels, wing_span, chord, airspeed, 0.04);
    try testing.expectApproxEqRel(linear_small, nonlinear_small, 0.01);
    // varredura em α: a linear cresce sempre; a não linear tem um máximo abaixo do c_l,max da seção (1,2 / 0,9)
    const default_surface = types.Surface{};
    const section_clmax = default_surface.CLmax / clmax_factor;
    var largest: f64 = 0;
    var alpha: f64 = 0.04;
    while (alpha < 0.45) : (alpha += 0.02) largest = @max(largest, rectLift(&params, &panels, wing_span, chord, airspeed, alpha));
    try testing.expect(largest < section_clmax and largest > 0.8 * section_clmax);
    const late = rectLift(&params, &panels, wing_span, chord, airspeed, 0.44);
    params.llt_nonlinear = 0;
    const late_linear = rectLift(&params, &panels, wing_span, chord, airspeed, 0.44);
    try testing.expect(late < 0.8 * late_linear);
    for (panels) |panel| try testing.expect(std.math.isFinite(panel.L));
}

test "não linear: na asa retangular a raiz chega ao estol antes da ponta" {
    var params = types.Params{};
    var panels: [32]types.PanelState = undefined;
    params.llt_nonlinear = 1;
    _ = rectLift(&params, &panels, 2.0, 0.25, 12.0, 0.2);
    try testing.expect(panels[16].CL > panels[1].CL); // c_l da raiz acima do da ponta: ela estola primeiro
}

test "não linear com o cache da geometria: o mesmo resultado, bit a bit" {
    var params = types.Params{};
    var panels: [24]types.PanelState = undefined;
    const alpha = 0.22;
    const airspeed = 12.0;
    rectWing(&params, &panels, 24, 2.0, 0.25, 2 * fmath.pi, airspeed, alpha);
    for (0..24) |i| {
        params.surf[i].r = panels[i].r;
        params.surf[i].side = panels[i].side;
    }
    params.llt_nonlinear = 1;
    const Vr = V3{ airspeed * @cos(alpha), 0, airspeed * @sin(alpha) };
    var cached = panels;
    var full = panels;
    prepare(&params);
    try testing.expect(params.llt_cache.nonlinear == 1);
    _ = apply(&params, Vr, vec.zero, cached[0..24]);
    params.llt_cache.ok = 0;
    _ = apply(&params, Vr, vec.zero, full[0..24]);
    for (0..24) |i| try testing.expectEqual(full[i].L, cached[i].L);
}
