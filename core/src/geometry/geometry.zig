//! Geometria do avião montado: se as peças cabem juntas antes de qualquer conta de aerodinâmica.
//!
//! Cada peça é uma primitiva simples no corpo (x para a frente, y para a direita, z para baixo):
//!   caixa orientada (`box`)   painel de asa ou de cauda, trecho de fuselagem, tubo, motor
//!   disco (`disc`)            a hélice: centro, eixo e raio
//!   ponto (`point`)           uma massa concentrada (bateria, carga, lastro) que precisa estar dentro de alguma caixa
//!
//! e a cena responde quatro perguntas, para um avião ou um lote:
//!   1. a hélice acerta alguma peça que não é o próprio motor? (disco × caixa, disco × disco)
//!   2. alguma massa concentrada ficou fora da geometria? (ponto dentro de caixa)
//!   3. o avião é uma peça só? (grafo: cada caixa é um nó, duas caixas que se encostam são uma aresta; o disco vai
//!      com o motor dele)
//!   4. algo bate no chão parado ou girado no trem principal até o ângulo de rotação? (a altura mínima de cada peça
//!      sobre o plano do chão, exata para a caixa e o disco)
//!
//! Interseção de caixas pelo teorema do eixo separador, 15 eixos (Gottschalk, Lin e Manocha, "OBBTree", SIGGRAPH
//! 1996; Ericson, Real-Time Collision Detection, 2005, seção 4.4.1, a conferir no PDF). Disco × caixa: o corte da
//! caixa pelo plano do disco é um polígono convexo, e o disco acerta a caixa se o centro dele cai dentro do polígono
//! ou se alguma aresta do polígono passa a menos de um raio do centro (a espessura do disco é desprezada).
const std = @import("std");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const max_parts = 96;
pub const max_report = 16;
pub const max_attitudes = 2;

pub const BOX: i32 = 0;
pub const DISC: i32 = 1;
pub const POINT: i32 = 2;

pub const Part = extern struct {
    kind: i32 = BOX,
    owner: i32 = 0, // o componente de onde a peça vem: o disco não colide com uma caixa do mesmo dono (o motor dele)
    c: [3]f64 = @splat(0), // centro (ponto: a posição; disco: o centro do disco)
    ax: [9]f64 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 }, // eixos da caixa, unitários (linhas); disco: ax[0..3] = eixo
    h: [3]f64 = @splat(0), // meias medidas da caixa ao longo de cada eixo; disco: h[0] = raio
};

pub const Scene = extern struct {
    n: i32 = 0,
    parts: [max_parts]Part = [_]Part{.{}} ** max_parts,
    pivot: [3]f64 = @splat(0), // ponto do chão sob o trem principal (y = 0), no corpo
    n_att: i32 = 0, // atitudes conferidas (rad, + nariz para cima): parado e girado até a rotação
    att: [max_attitudes]f64 = @splat(0),
    clearance: f64 = 0, // folga mínima de qualquer peça ao chão (m)
    prop_clearance: f64 = 0, // folga mínima da hélice ao chão (m)
    contact_tol: f64 = 0.005, // duas caixas a menos disso se encostam (m)
    hub: f64 = 0.035, // a hélice está presa à caixa que tem o centro dela a menos disso (o cubo, o motor): não a acerta
    need_connected: i32 = 1, // 0: os pedaços soltos só são contados, não reprovam
};

pub const Report = extern struct {
    ok: i32 = 1,
    n_hits: i32 = 0, // hélice × peça (disco, caixa), índices das peças
    hit_a: [max_report]i32 = @splat(-1),
    hit_b: [max_report]i32 = @splat(-1),
    n_outside: i32 = 0, // massas fora de toda caixa
    outside: [max_report]i32 = @splat(-1),
    n_groups: i32 = 0, // pedaços soltos (1 = o avião é uma peça só); group[i] = o pedaço da peça i (−1 = ponto)
    group: [max_parts]i32 = @splat(-1),
    low: [max_attitudes]f64 = @splat(0), // em cada atitude: a menor folga ao chão (já descontada a folga pedida)
    low_part: [max_attitudes]i32 = @splat(-1),
};

fn v(a: [3]f64) V3 {
    return .{ a[0], a[1], a[2] };
}

fn dot(a: V3, b: V3) f64 {
    return @reduce(.Add, a * b);
}

fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn axis(p: *const Part, i: usize) V3 {
    return .{ p.ax[3 * i], p.ax[3 * i + 1], p.ax[3 * i + 2] };
}

/// meia largura da caixa projetada na direção `d`
fn radiusAlong(p: *const Part, d: V3) f64 {
    var r: f64 = 0;
    for (0..3) |i| r += p.h[i] * @abs(dot(axis(p, i), d));
    return r;
}

/// duas caixas se cruzam (ou ficam a menos de `tol`)? eixo separador: os 3 + 3 eixos das caixas e os 9 produtos
pub fn boxesTouch(a: *const Part, b: *const Part, tol: f64) bool {
    const t = v(b.c) - v(a.c);
    var axes: [15]V3 = undefined;
    for (0..3) |i| {
        axes[i] = axis(a, i);
        axes[3 + i] = axis(b, i);
        for (0..3) |j| axes[6 + 3 * i + j] = cross(axis(a, i), axis(b, j));
    }
    for (axes) |d| {
        const n2 = dot(d, d);
        if (n2 < 1e-18) continue; // eixos paralelos: o produto some e os eixos das caixas já cobrem
        const u = d / @as(V3, @splat(@sqrt(n2)));
        if (@abs(dot(t, u)) > radiusAlong(a, u) + radiusAlong(b, u) + tol) return false;
    }
    return true;
}

pub fn pointInBox(p: V3, b: *const Part) bool {
    return pointNearBox(p, b, 0);
}

/// o ponto está dentro da caixa crescida de `tol` em cada eixo?
pub fn pointNearBox(p: V3, b: *const Part, tol: f64) bool {
    const d = p - v(b.c);
    for (0..3) |i| {
        if (@abs(dot(d, axis(b, i))) > b.h[i] + tol + 1e-12) return false;
    }
    return true;
}

/// o disco acerta a caixa? o corte da caixa pelo plano do disco contra o círculo
pub fn discHitsBox(d: *const Part, b: *const Part) bool {
    const c = v(d.c);
    const n = axis(d, 0);
    const R = d.h[0];
    // o plano do disco precisa cortar a caixa, entrando mais que 1 mm: a caixa que só encosta no disco (o nariz
    // da fuselagem atrás da hélice tratora, o suporte do motor) não conta
    if (@abs(dot(v(b.c) - c, n)) > radiusAlong(b, n) - 1e-3) return false;
    // as 12 arestas da caixa cortadas pelo plano: os pontos de corte formam o polígono
    var corners: [8]V3 = undefined;
    for (0..8) |k| {
        var p = v(b.c);
        for (0..3) |i| {
            const s: f64 = if ((k >> @intCast(i)) & 1 == 1) 1 else -1;
            p += axis(b, i) * @as(V3, @splat(s * b.h[i]));
        }
        corners[k] = p;
    }
    // base do plano: u, w perpendiculares ao eixo
    const ref: V3 = if (@abs(n[2]) < 0.9) .{ 0, 0, 1 } else .{ 0, 1, 0 };
    var u = cross(n, ref);
    u /= @as(V3, @splat(@sqrt(dot(u, u))));
    const w = cross(n, u);
    var pts: [12][2]f64 = undefined;
    var m: usize = 0;
    for (0..8) |i| {
        for (0..3) |bit| {
            const j = i ^ (@as(usize, 1) << @intCast(bit));
            if (j < i) continue; // cada aresta uma vez
            const si = dot(corners[i] - c, n);
            const sj = dot(corners[j] - c, n);
            if ((si > 0 and sj > 0) or (si < 0 and sj < 0)) continue;
            const f = if (si == sj) 0.5 else si / (si - sj);
            const q = corners[i] + (corners[j] - corners[i]) * @as(V3, @splat(f)) - c;
            pts[m] = .{ dot(q, u), dot(q, w) };
            m += 1;
        }
    }
    if (m == 0) return false;
    // ordena pelo ângulo em volta do centroide: o polígono convexo do corte
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pts[0..m]) |p| {
        cx += p[0];
        cy += p[1];
    }
    cx /= @floatFromInt(m);
    cy /= @floatFromInt(m);
    var ang: [12]f64 = undefined;
    for (0..m) |i| ang[i] = std.math.atan2(pts[i][1] - cy, pts[i][0] - cx);
    for (1..m) |i| { // inserção: poucos pontos
        var j = i;
        while (j > 0 and ang[j - 1] > ang[j]) : (j -= 1) {
            std.mem.swap(f64, &ang[j - 1], &ang[j]);
            std.mem.swap([2]f64, &pts[j - 1], &pts[j]);
        }
    }
    // centro do disco (a origem) dentro do polígono, ou alguma aresta a menos de R
    var inside = m >= 3;
    for (0..m) |i| {
        const a = pts[i];
        const b2 = pts[(i + 1) % m];
        const ex = b2[0] - a[0];
        const ey = b2[1] - a[1];
        if (m >= 3 and ex * (0 - a[1]) - ey * (0 - a[0]) < 0) inside = false;
        const l2 = ex * ex + ey * ey;
        const t = if (l2 > 0) std.math.clamp(-(a[0] * ex + a[1] * ey) / l2, 0, 1) else 0;
        const px = a[0] + t * ex;
        const py = a[1] + t * ey;
        if (px * px + py * py <= R * R) return true;
    }
    return inside;
}

/// dois discos se cruzam? (os círculos, nos planos deles: perto o bastante e um corta o plano do outro dentro do raio)
pub fn discsTouch(a: *const Part, b: *const Part) bool {
    const d = v(b.c) - v(a.c);
    const ra = a.h[0];
    const rb = b.h[0];
    if (dot(d, d) > (ra + rb) * (ra + rb)) return false;
    // coplanares ou quase: basta a distância; senão, a reta de interseção dos planos tem que cortar os dois círculos
    const na = axis(a, 0);
    const nb = axis(b, 0);
    const l = cross(na, nb);
    const l2 = dot(l, l);
    if (l2 < 1e-12) return @abs(dot(d, na)) < 1e-3;
    // ponto da reta: resolve na·p = na·ca, nb·p = nb·cb, l·p = l·ca
    const ca = v(a.c);
    const cb = v(b.c);
    const p = vec.solve3(.{ na, nb, l }, .{ dot(na, ca), dot(nb, cb), dot(l, ca) });
    const lu = l / @as(V3, @splat(@sqrt(l2)));
    // intervalo da reta dentro de cada círculo
    const ia = chord(p, lu, ca, ra) orelse return false;
    const ib = chord(p, lu, cb, rb) orelse return false;
    return ia[0] <= ib[1] and ib[0] <= ia[1];
}

fn chord(p: V3, lu: V3, c: V3, r: f64) ?[2]f64 {
    const t0 = dot(c - p, lu);
    const q = p + lu * @as(V3, @splat(t0)) - c;
    const d2 = dot(q, q);
    if (d2 > r * r) return null;
    const hw = @sqrt(r * r - d2);
    return .{ t0 - hw, t0 + hw };
}

/// a menor altura da peça sobre o chão, com o avião girado `theta` (nariz para cima) em volta do pivô no chão
pub fn lowest(p: *const Part, pivot: V3, theta: f64) f64 {
    // altura de um ponto: h = dx sen θ − dz cos θ (z para baixo); é linear, então o mínimo é exato
    const g: V3 = .{ @sin(theta), 0, -@cos(theta) };
    const h0 = dot(v(p.c) - pivot, g);
    return switch (p.kind) {
        BOX => h0 - radiusAlong(p, g),
        DISC => blk: {
            const a = dot(g, axis(p, 0));
            break :blk h0 - p.h[0] * @sqrt(@max(dot(g, g) - a * a, 0));
        },
        else => h0,
    };
}

/// alguma caixa do dono `owner` tem o centro do disco a menos de `hub`?
fn mountedOn(ps: []const Part, d: *const Part, owner: i32, hub: f64) bool {
    for (ps) |*b| {
        if (b.kind == BOX and b.owner == owner and pointNearBox(v(d.c), b, hub)) return true;
    }
    return false;
}

fn find(parent: []i32, i: usize) usize {
    var r = i;
    while (parent[r] != @as(i32, @intCast(r))) r = @intCast(parent[r]);
    return r;
}

pub fn check(s: *const Scene) Report {
    var r = Report{};
    const n: usize = @intCast(std.math.clamp(s.n, 0, max_parts));
    const ps = s.parts[0..n];
    // 1. hélice × peça; a peça onde a hélice está presa (o centro dela a menos de um cubo) não conta: é o nariz da
    // fuselagem com o motor, a nacele na asa, o tubo que segura a propulsora
    for (ps, 0..) |*a, i| {
        if (a.kind != DISC) continue;
        for (ps, 0..) |*b, j| {
            if (j == i or b.kind == POINT or b.owner == a.owner) continue;
            if (b.kind == BOX and mountedOn(ps, a, b.owner, s.hub)) continue;
            if (b.kind == DISC and j < i) continue;
            const hit = if (b.kind == DISC) discsTouch(a, b) else discHitsBox(a, b);
            if (hit) {
                if (r.n_hits < max_report) {
                    r.hit_a[@intCast(r.n_hits)] = @intCast(i);
                    r.hit_b[@intCast(r.n_hits)] = @intCast(j);
                }
                r.n_hits += 1;
            }
        }
    }
    // 2. massas dentro de alguma caixa
    for (ps, 0..) |*a, i| {
        if (a.kind != POINT) continue;
        var in = false;
        for (ps) |*b| {
            if (b.kind == BOX and pointInBox(v(a.c), b)) {
                in = true;
                break;
            }
        }
        if (!in) {
            if (r.n_outside < max_report) r.outside[@intCast(r.n_outside)] = @intCast(i);
            r.n_outside += 1;
        }
    }
    // 3. pedaços: união das caixas que se encostam; o disco vai com o dono
    var parent: [max_parts]i32 = undefined;
    for (0..n) |i| parent[i] = @intCast(i);
    for (ps, 0..) |*a, i| {
        if (a.kind != BOX) continue;
        for (ps[i + 1 ..], i + 1..) |*b, j| {
            if (b.kind != BOX) continue;
            if (a.owner == b.owner or boxesTouch(a, b, s.contact_tol)) {
                const ra = find(parent[0..n], i);
                const rb = find(parent[0..n], j);
                if (ra != rb) parent[rb] = @intCast(ra);
            }
        }
    }
    for (ps, 0..) |*a, i| { // o disco: com a primeira caixa do mesmo dono
        if (a.kind != DISC) continue;
        for (ps, 0..) |*b, j| {
            if (b.kind == BOX and b.owner == a.owner) {
                parent[find(parent[0..n], i)] = @intCast(find(parent[0..n], j));
                break;
            }
        }
    }
    var label: [max_parts]i32 = @splat(-1);
    for (ps, 0..) |*a, i| {
        if (a.kind == POINT) continue;
        const root = find(parent[0..n], i);
        if (label[root] < 0) {
            label[root] = r.n_groups;
            r.n_groups += 1;
        }
        r.group[i] = label[root];
    }
    // 4. chão
    const pv = v(s.pivot);
    const na: usize = @intCast(std.math.clamp(s.n_att, 0, max_attitudes));
    for (0..na) |k| {
        var best = std.math.inf(f64);
        for (ps, 0..) |*a, i| {
            if (a.kind == POINT) continue;
            const need = if (a.kind == DISC) s.prop_clearance else s.clearance;
            const f = lowest(a, pv, s.att[k]) - need;
            if (f < best) {
                best = f;
                r.low_part[k] = @intCast(i);
            }
        }
        r.low[k] = best;
        if (best < 0) r.ok = 0;
    }
    if (r.n_hits > 0 or r.n_outside > 0 or (s.need_connected != 0 and r.n_groups > 1)) r.ok = 0;
    return r;
}

pub fn checkMany(scenes: []const Scene, out: []Report) void {
    for (scenes, out) |*s, *o| o.* = check(s);
}

// ------------------------------------------------------------------ testes
fn boxAt(c: [3]f64, h: [3]f64, owner: i32) Part {
    return .{ .kind = BOX, .owner = owner, .c = c, .h = h };
}

fn discAt(c: [3]f64, n: [3]f64, R: f64, owner: i32) Part {
    return .{ .kind = DISC, .owner = owner, .c = c, .ax = .{ n[0], n[1], n[2], 0, 0, 0, 0, 0, 0 }, .h = .{ R, 0, 0 } };
}

test "caixas: encostam, se cruzam e ficam longe" {
    const a = boxAt(.{ 0, 0, 0 }, .{ 1, 1, 1 }, 0);
    try std.testing.expect(boxesTouch(&a, &boxAt(.{ 1.9, 0, 0 }, .{ 1, 1, 1 }, 1), 0));
    try std.testing.expect(!boxesTouch(&a, &boxAt(.{ 2.1, 0, 0 }, .{ 1, 1, 1 }, 1), 0));
    try std.testing.expect(boxesTouch(&a, &boxAt(.{ 2.1, 0, 0 }, .{ 1, 1, 1 }, 1), 0.2));
    // girada 45° em z: a ponta chega a √2 do centro
    const s = @sqrt(0.5);
    var b = boxAt(.{ 2.3, 0, 0 }, .{ 1, 1, 1 }, 1);
    b.ax = .{ s, s, 0, -s, s, 0, 0, 0, 1 };
    try std.testing.expect(boxesTouch(&a, &b, 0)); // 1 + √2 = 2,41 > 2,3
    b.c = .{ 2.5, 0, 0 };
    try std.testing.expect(!boxesTouch(&a, &b, 0));
}

test "hélice atravessada por um tubo, e ao lado dele" {
    // tubo de cauda ao longo de x, raio 1 cm; hélice propulsora em x = −0,3, eixo x, raio 0,15
    const tubo = boxAt(.{ -0.6, 0, 0 }, .{ 0.5, 0.01, 0.01 }, 0);
    try std.testing.expect(discHitsBox(&discAt(.{ -0.3, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1), &tubo));
    // a hélice deslocada 0,2 m para o lado: o tubo passa fora do disco
    try std.testing.expect(!discHitsBox(&discAt(.{ -0.3, 0.2, 0 }, .{ 1, 0, 0 }, 0.15, 1), &tubo));
    // a 0,155 m: o tubo (meia largura 0,01) fica a 0,145 do centro, dentro do raio
    try std.testing.expect(discHitsBox(&discAt(.{ -0.3, 0.155, 0 }, .{ 1, 0, 0 }, 0.15, 1), &tubo));
    // uma asa fina cortando o disco fora do centro (a 0,1 m acima)
    const asa = boxAt(.{ -0.3, 0, -0.1 }, .{ 0.1, 1.0, 0.01 }, 2);
    try std.testing.expect(discHitsBox(&discAt(.{ -0.3, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1), &asa));
    try std.testing.expect(!discHitsBox(&discAt(.{ -0.3, 0, 0 }, .{ 1, 0, 0 }, 0.08, 1), &asa));
    // a fuselagem logo atrás da hélice tratora, encostada no disco: não acerta
    const fus = boxAt(.{ -0.5, 0, 0 }, .{ 0.2, 0.05, 0.05 }, 3);
    try std.testing.expect(!discHitsBox(&discAt(.{ -0.3, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1), &fus));
}

test "duas hélices lado a lado" {
    const a = discAt(.{ 0, -0.2, 0 }, .{ 1, 0, 0 }, 0.15, 0);
    try std.testing.expect(discsTouch(&a, &discAt(.{ 0, 0.05, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    try std.testing.expect(!discsTouch(&a, &discAt(.{ 0, 0.2, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    // em planos diferentes (uma mais à frente): não se tocam mesmo com os raios somando mais que a distância
    try std.testing.expect(!discsTouch(&a, &discAt(.{ 0.1, 0.05, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    // inclinadas uma para a outra: os planos se cortam dentro dos dois círculos
    const s = @sqrt(0.5);
    try std.testing.expect(discsTouch(&discAt(.{ 0, 0, 0 }, .{ s, s, 0 }, 0.15, 0), &discAt(.{ 0, 0.2, 0 }, .{ s, -s, 0 }, 0.15, 1)));
}

test "altura ao chão: caixa e disco, parado e girado" {
    const pv: V3 = .{ 0, 0, 0.2 }; // chão 0,2 m abaixo da referência
    // caixa de cauda 1 m atrás, base em z = 0,05: 0,15 m acima do chão parado
    const cauda = boxAt(.{ -1, 0, 0 }, .{ 0.1, 0.1, 0.05 }, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), lowest(&cauda, pv, 0), 1e-12);
    // girado 10°: a quina de trás de baixo (x = −1,1, z = 0,05) desce: h = −1,1 sen 10° + 0,15 cos 10°
    const th = 10.0 * std.math.pi / 180.0;
    try std.testing.expectApproxEqAbs(-1.1 * @sin(th) + 0.15 * @cos(th), lowest(&cauda, pv, th), 1e-12);
    // hélice no nariz, eixo x, raio 0,15, centro em z = 0: ponta de baixo a 0,05 m do chão
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), lowest(&discAt(.{ 0.5, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1), pv, 0), 1e-12);
}

test "a hélice presa no nariz não acerta a fuselagem; um tubo que passa fora do cubo acerta" {
    var s = Scene{ .n = 4 };
    s.parts[0] = boxAt(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem, nariz em x = 0,4
    s.parts[1] = discAt(.{ 0.38, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1); // hélice 2 cm atrás do nariz (o cone entra nela)
    s.parts[2] = boxAt(.{ 0.33, 0, 0 }, .{ 0.05, 0.03, 0.03 }, 1); // o motor
    s.parts[3] = boxAt(.{ 0.6, 0.08, 0 }, .{ 0.3, 0.01, 0.01 }, 2); // uma vareta a 8 cm do eixo, atravessando o disco
    const r = check(&s);
    try std.testing.expectEqual(@as(i32, 1), r.n_hits);
    try std.testing.expectEqual(@as(i32, 3), r.hit_b[0]);
}

test "cena: pedaço solto, massa fora e cauda no chão" {
    var s = Scene{ .n = 4, .pivot = .{ 0, 0, 0.2 }, .n_att = 2, .att = .{ 0, 12.0 * std.math.pi / 180.0 } };
    s.parts[0] = boxAt(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem
    s.parts[1] = boxAt(.{ 0, 0, -0.07 }, .{ 0.12, 0.8, 0.01 }, 1); // asa sobre ela
    s.parts[2] = boxAt(.{ -1.0, 0, 0 }, .{ 0.1, 0.3, 0.005 }, 2); // EH solta, sem tubo
    s.parts[3] = .{ .kind = POINT, .owner = 3, .c = .{ 0.1, 0, 0 } }; // bateria na fuselagem
    var r = check(&s);
    try std.testing.expectEqual(@as(i32, 2), r.n_groups);
    try std.testing.expectEqual(@as(i32, 0), r.n_outside);
    try std.testing.expect(r.ok == 0);
    s.need_connected = 0; // só contados: parado, o resto passa
    s.n_att = 1;
    try std.testing.expect(check(&s).ok == 1 and check(&s).n_groups == 2);
    s.need_connected = 1;
    s.n_att = 2;
    // o tubo liga a EH: uma peça só; girado 12° a EH (a 1,1 m atrás, 0,2 m acima do chão) bate
    s.parts[4] = boxAt(.{ -0.55, 0, 0 }, .{ 0.45, 0.01, 0.01 }, 4);
    s.n = 5;
    r = check(&s);
    try std.testing.expectEqual(@as(i32, 1), r.n_groups);
    try std.testing.expect(r.low[0] > 0 and r.low[1] < 0);
    try std.testing.expectEqual(@as(i32, 2), r.low_part[1]);
    // a bateria fora de tudo
    s.parts[3].c = .{ 0.1, 0.5, 0.3 };
    r = check(&s);
    try std.testing.expectEqual(@as(i32, 1), r.n_outside);
    try std.testing.expectEqual(@as(i32, 3), r.outside[0]);
}
