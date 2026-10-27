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
    gear_raise: f64 = 0, // quanto descer as rodas (todas juntas, a atitude parada não muda) para tudo livrar o chão (m)
};

fn toV3(coords: [3]f64) V3 {
    return .{ coords[0], coords[1], coords[2] };
}

fn dot(lhs: V3, rhs: V3) f64 {
    return @reduce(.Add, lhs * rhs);
}

fn cross(lhs: V3, rhs: V3) V3 {
    return .{ lhs[1] * rhs[2] - lhs[2] * rhs[1], lhs[2] * rhs[0] - lhs[0] * rhs[2], lhs[0] * rhs[1] - lhs[1] * rhs[0] };
}

fn axis(part: *const Part, i: usize) V3 {
    return .{ part.ax[3 * i], part.ax[3 * i + 1], part.ax[3 * i + 2] };
}

/// meia largura da caixa projetada na direção `direction`
fn radiusAlong(part: *const Part, direction: V3) f64 {
    var radius: f64 = 0;
    for (0..3) |i| radius += part.h[i] * @abs(dot(axis(part, i), direction));
    return radius;
}

/// duas caixas se cruzam (ou ficam a menos de `tol`)? eixo separador: os 3 + 3 eixos das caixas e os 9 produtos
pub fn boxesTouch(box_a: *const Part, box_b: *const Part, tol: f64) bool {
    const offset = toV3(box_b.c) - toV3(box_a.c);
    var axes: [15]V3 = undefined;
    for (0..3) |i| {
        axes[i] = axis(box_a, i);
        axes[3 + i] = axis(box_b, i);
        for (0..3) |j| axes[6 + 3 * i + j] = cross(axis(box_a, i), axis(box_b, j));
    }
    for (axes) |candidate| {
        const n2 = dot(candidate, candidate);
        if (n2 < 1e-18) continue; // eixos paralelos: o produto some e os eixos das caixas já cobrem
        const unit = candidate / @as(V3, @splat(@sqrt(n2)));
        if (@abs(dot(offset, unit)) > radiusAlong(box_a, unit) + radiusAlong(box_b, unit) + tol) return false;
    }
    return true;
}

/// o ponto está dentro da caixa?
pub fn pointInBox(point: V3, box: *const Part) bool {
    return pointNearBox(point, box, 0);
}

/// o ponto está dentro da caixa crescida de `tol` em cada eixo?
pub fn pointNearBox(point: V3, box: *const Part, tol: f64) bool {
    const offset = point - toV3(box.c);
    for (0..3) |i| {
        if (@abs(dot(offset, axis(box, i))) > box.h[i] + tol + 1e-12) return false;
    }
    return true;
}

/// o disco acerta a caixa? o corte da caixa pelo plano do disco contra o círculo
pub fn discHitsBox(disc: *const Part, box: *const Part) bool {
    const center = toV3(disc.c);
    const normal = axis(disc, 0);
    const radius = disc.h[0];
    // o plano do disco precisa cortar a caixa, entrando mais que 1 mm: a caixa que só encosta no disco (o nariz
    // da fuselagem atrás da hélice tratora, o suporte do motor) não conta
    if (@abs(dot(toV3(box.c) - center, normal)) > radiusAlong(box, normal) - 1e-3) return false;
    // as 12 arestas da caixa cortadas pelo plano: os pontos de corte formam o polígono
    var corners: [8]V3 = undefined;
    for (0..8) |k| {
        var corner = toV3(box.c);
        for (0..3) |i| {
            const sign: f64 = if ((k >> @intCast(i)) & 1 == 1) 1 else -1;
            corner += axis(box, i) * @as(V3, @splat(sign * box.h[i]));
        }
        corners[k] = corner;
    }
    // base do plano: u, w perpendiculares ao eixo
    const ref: V3 = if (@abs(normal[2]) < 0.9) .{ 0, 0, 1 } else .{ 0, 1, 0 };
    var basis_u = cross(normal, ref);
    basis_u /= @as(V3, @splat(@sqrt(dot(basis_u, basis_u))));
    const basis_w = cross(normal, basis_u);
    var pts: [12][2]f64 = undefined;
    var cut_count: usize = 0;
    for (0..8) |i| {
        for (0..3) |bit| {
            const j = i ^ (@as(usize, 1) << @intCast(bit));
            if (j < i) continue; // cada aresta uma vez
            const si = dot(corners[i] - center, normal);
            const sj = dot(corners[j] - center, normal);
            if ((si > 0 and sj > 0) or (si < 0 and sj < 0)) continue;
            const fraction = if (si == sj) 0.5 else si / (si - sj);
            const cut_point = corners[i] + (corners[j] - corners[i]) * @as(V3, @splat(fraction)) - center;
            pts[cut_count] = .{ dot(cut_point, basis_u), dot(cut_point, basis_w) };
            cut_count += 1;
        }
    }
    if (cut_count == 0) return false;
    // ordena pelo ângulo em volta do centroide: o polígono convexo do corte
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pts[0..cut_count]) |corner| {
        cx += corner[0];
        cy += corner[1];
    }
    cx /= @floatFromInt(cut_count);
    cy /= @floatFromInt(cut_count);
    var ang: [12]f64 = undefined;
    for (0..cut_count) |i| ang[i] = std.math.atan2(pts[i][1] - cy, pts[i][0] - cx);
    for (1..cut_count) |i| { // inserção: poucos pontos
        var j = i;
        while (j > 0 and ang[j - 1] > ang[j]) : (j -= 1) {
            std.mem.swap(f64, &ang[j - 1], &ang[j]);
            std.mem.swap([2]f64, &pts[j - 1], &pts[j]);
        }
    }
    // centro do disco (a origem) dentro do polígono, ou alguma aresta a menos de R
    var inside = cut_count >= 3;
    for (0..cut_count) |i| {
        const edge_start = pts[i];
        const b2 = pts[(i + 1) % cut_count];
        const ex = b2[0] - edge_start[0];
        const ey = b2[1] - edge_start[1];
        if (cut_count >= 3 and ex * (0 - edge_start[1]) - ey * (0 - edge_start[0]) < 0) inside = false;
        const l2 = ex * ex + ey * ey;
        const along = if (l2 > 0) std.math.clamp(-(edge_start[0] * ex + edge_start[1] * ey) / l2, 0, 1) else 0;
        const px = edge_start[0] + along * ex;
        const py = edge_start[1] + along * ey;
        if (px * px + py * py <= radius * radius) return true;
    }
    return inside;
}

/// dois discos se cruzam? (os círculos, nos planos deles: perto o bastante e um corta o plano do outro dentro do raio)
pub fn discsTouch(disc_a: *const Part, disc_b: *const Part) bool {
    const offset = toV3(disc_b.c) - toV3(disc_a.c);
    const ra = disc_a.h[0];
    const rb = disc_b.h[0];
    if (dot(offset, offset) > (ra + rb) * (ra + rb)) return false;
    // coplanares ou quase: basta a distância; senão, a reta de interseção dos planos tem que cortar os dois círculos
    const na = axis(disc_a, 0);
    const nb = axis(disc_b, 0);
    const line_dir = cross(na, nb);
    const l2 = dot(line_dir, line_dir);
    if (l2 < 1e-12) return @abs(dot(offset, na)) < 1e-3;
    // ponto da reta: resolve na·p = na·ca, nb·p = nb·cb, l·p = l·ca
    const ca = toV3(disc_a.c);
    const cb = toV3(disc_b.c);
    const line_point = vec.solve3(.{ na, nb, line_dir }, .{ dot(na, ca), dot(nb, cb), dot(line_dir, ca) });
    const lu = line_dir / @as(V3, @splat(@sqrt(l2)));
    // intervalo da reta dentro de cada círculo
    const ia = chord(line_point, lu, ca, ra) orelse return false;
    const ib = chord(line_point, lu, cb, rb) orelse return false;
    return ia[0] <= ib[1] and ib[0] <= ia[1];
}

fn chord(line_point: V3, lu: V3, center: V3, radius: f64) ?[2]f64 {
    const t0 = dot(center - line_point, lu);
    const closest = line_point + lu * @as(V3, @splat(t0)) - center;
    const d2 = dot(closest, closest);
    if (d2 > radius * radius) return null;
    const hw = @sqrt(radius * radius - d2);
    return .{ t0 - hw, t0 + hw };
}

/// a menor altura da peça sobre o chão, com o avião girado `theta` (nariz para cima) em volta do pivô no chão
pub fn lowest(part: *const Part, pivot: V3, theta: f64) f64 {
    // altura de um ponto: h = dx sen θ − dz cos θ (z para baixo); é linear, então o mínimo é exato
    const down_dir: V3 = .{ @sin(theta), 0, -@cos(theta) };
    const h0 = dot(toV3(part.c) - pivot, down_dir);
    return switch (part.kind) {
        BOX => h0 - radiusAlong(part, down_dir),
        DISC => blk: {
            const axis_cos = dot(down_dir, axis(part, 0));
            break :blk h0 - part.h[0] * @sqrt(@max(dot(down_dir, down_dir) - axis_cos * axis_cos, 0));
        },
        else => h0,
    };
}

/// alguma caixa do dono `owner` tem o centro do disco a menos de `hub`?
fn mountedOn(parts: []const Part, disc: *const Part, owner: i32, hub: f64) bool {
    for (parts) |*box| {
        if (box.kind == BOX and box.owner == owner and pointNearBox(toV3(disc.c), box, hub)) return true;
    }
    return false;
}

fn find(parent: []i32, i: usize) usize {
    var root = i;
    while (parent[root] != @as(i32, @intCast(root))) root = @intCast(parent[root]);
    return root;
}

/// confere uma cena: hélice × peças, massas fora, pedaços soltos e folga ao chão em cada atitude
pub fn check(scene: *const Scene) Report {
    var report = Report{};
    const count: usize = @intCast(std.math.clamp(scene.n, 0, max_parts));
    const parts = scene.parts[0..count];
    // 1. hélice × peça; a peça onde a hélice está presa (o centro dela a menos de um cubo) não conta: é o nariz da
    // fuselagem com o motor, a nacele na asa, o tubo que segura a propulsora
    for (parts, 0..) |*part_a, i| {
        if (part_a.kind != DISC) continue;
        for (parts, 0..) |*part_b, j| {
            if (j == i or part_b.kind == POINT or part_b.owner == part_a.owner) continue;
            if (part_b.kind == BOX and mountedOn(parts, part_a, part_b.owner, scene.hub)) continue;
            if (part_b.kind == DISC and j < i) continue;
            const hit = if (part_b.kind == DISC) discsTouch(part_a, part_b) else discHitsBox(part_a, part_b);
            if (hit) {
                if (report.n_hits < max_report) {
                    report.hit_a[@intCast(report.n_hits)] = @intCast(i);
                    report.hit_b[@intCast(report.n_hits)] = @intCast(j);
                }
                report.n_hits += 1;
            }
        }
    }
    // 2. massas dentro de alguma caixa
    for (parts, 0..) |*part_a, i| {
        if (part_a.kind != POINT) continue;
        var in = false;
        for (parts) |*part_b| {
            if (part_b.kind == BOX and pointInBox(toV3(part_a.c), part_b)) {
                in = true;
                break;
            }
        }
        if (!in) {
            if (report.n_outside < max_report) report.outside[@intCast(report.n_outside)] = @intCast(i);
            report.n_outside += 1;
        }
    }
    // 3. pedaços: união das caixas que se encostam; o disco vai com o dono
    var parent: [max_parts]i32 = undefined;
    for (0..count) |i| parent[i] = @intCast(i);
    for (parts, 0..) |*part_a, i| {
        if (part_a.kind != BOX) continue;
        for (parts[i + 1 ..], i + 1..) |*part_b, j| {
            if (part_b.kind != BOX) continue;
            if (part_a.owner == part_b.owner or boxesTouch(part_a, part_b, scene.contact_tol)) {
                const ra = find(parent[0..count], i);
                const rb = find(parent[0..count], j);
                if (ra != rb) parent[rb] = @intCast(ra);
            }
        }
    }
    for (parts, 0..) |*part_a, i| { // o disco: com a primeira caixa do mesmo dono
        if (part_a.kind != DISC) continue;
        for (parts, 0..) |*part_b, j| {
            if (part_b.kind == BOX and part_b.owner == part_a.owner) {
                parent[find(parent[0..count], i)] = @intCast(find(parent[0..count], j));
                break;
            }
        }
    }
    var label: [max_parts]i32 = @splat(-1);
    for (parts, 0..) |*part_a, i| {
        if (part_a.kind == POINT) continue;
        const root = find(parent[0..count], i);
        if (label[root] < 0) {
            label[root] = report.n_groups;
            report.n_groups += 1;
        }
        report.group[i] = label[root];
    }
    // 4. chão
    const pv = toV3(scene.pivot);
    const attitude_count: usize = @intCast(std.math.clamp(scene.n_att, 0, max_attitudes));
    for (0..attitude_count) |k| {
        var best = std.math.inf(f64);
        for (parts, 0..) |*part_a, i| {
            if (part_a.kind == POINT) continue;
            const need = if (part_a.kind == DISC) scene.prop_clearance else scene.clearance;
            const gap = lowest(part_a, pv, scene.att[k]) - need;
            if (gap < best) {
                best = gap;
                report.low_part[k] = @intCast(i);
            }
        }
        report.low[k] = best;
        if (best < 0) {
            report.ok = 0;
            // descer as rodas Δ desce o pivô Δ no corpo, e a altura de todo ponto girado de θ sobe Δ cos θ
            report.gear_raise = @max(report.gear_raise, -best / @cos(scene.att[k]));
        }
    }
    if (report.n_hits > 0 or report.n_outside > 0 or (scene.need_connected != 0 and report.n_groups > 1)) report.ok = 0;
    return report;
}

/// `check` em cada cena, resultado em `out`
pub fn checkMany(scenes: []const Scene, out: []Report) void {
    for (scenes, out) |*scene, *report| report.* = check(scene);
}

// ------------------------------------------------------------------ testes
fn boxAt(center: [3]f64, half: [3]f64, owner: i32) Part {
    return .{ .kind = BOX, .owner = owner, .c = center, .h = half };
}

fn discAt(center: [3]f64, normal: [3]f64, radius: f64, owner: i32) Part {
    return .{ .kind = DISC, .owner = owner, .c = center, .ax = .{ normal[0], normal[1], normal[2], 0, 0, 0, 0, 0, 0 }, .h = .{ radius, 0, 0 } };
}

test "caixas: encostam, se cruzam e ficam longe" {
    const first = boxAt(.{ 0, 0, 0 }, .{ 1, 1, 1 }, 0);
    try std.testing.expect(boxesTouch(&first, &boxAt(.{ 1.9, 0, 0 }, .{ 1, 1, 1 }, 1), 0));
    try std.testing.expect(!boxesTouch(&first, &boxAt(.{ 2.1, 0, 0 }, .{ 1, 1, 1 }, 1), 0));
    try std.testing.expect(boxesTouch(&first, &boxAt(.{ 2.1, 0, 0 }, .{ 1, 1, 1 }, 1), 0.2));
    // girada 45° em z: a ponta chega a √2 do centro
    const half_sqrt2 = @sqrt(0.5);
    var second = boxAt(.{ 2.3, 0, 0 }, .{ 1, 1, 1 }, 1);
    second.ax = .{ half_sqrt2, half_sqrt2, 0, -half_sqrt2, half_sqrt2, 0, 0, 0, 1 };
    try std.testing.expect(boxesTouch(&first, &second, 0)); // 1 + √2 = 2,41 > 2,3
    second.c = .{ 2.5, 0, 0 };
    try std.testing.expect(!boxesTouch(&first, &second, 0));
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
    const first = discAt(.{ 0, -0.2, 0 }, .{ 1, 0, 0 }, 0.15, 0);
    try std.testing.expect(discsTouch(&first, &discAt(.{ 0, 0.05, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    try std.testing.expect(!discsTouch(&first, &discAt(.{ 0, 0.2, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    // em planos diferentes (uma mais à frente): não se tocam mesmo com os raios somando mais que a distância
    try std.testing.expect(!discsTouch(&first, &discAt(.{ 0.1, 0.05, 0 }, .{ 1, 0, 0 }, 0.15, 1)));
    // inclinadas uma para a outra: os planos se cortam dentro dos dois círculos
    const half_sqrt2 = @sqrt(0.5);
    try std.testing.expect(discsTouch(&discAt(.{ 0, 0, 0 }, .{ half_sqrt2, half_sqrt2, 0 }, 0.15, 0), &discAt(.{ 0, 0.2, 0 }, .{ half_sqrt2, -half_sqrt2, 0 }, 0.15, 1)));
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
    var scene = Scene{ .n = 4 };
    scene.parts[0] = boxAt(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem, nariz em x = 0,4
    scene.parts[1] = discAt(.{ 0.38, 0, 0 }, .{ 1, 0, 0 }, 0.15, 1); // hélice 2 cm atrás do nariz (o cone entra nela)
    scene.parts[2] = boxAt(.{ 0.33, 0, 0 }, .{ 0.05, 0.03, 0.03 }, 1); // o motor
    scene.parts[3] = boxAt(.{ 0.6, 0.08, 0 }, .{ 0.3, 0.01, 0.01 }, 2); // uma vareta a 8 cm do eixo, atravessando o disco
    const report = check(&scene);
    try std.testing.expectEqual(@as(i32, 1), report.n_hits);
    try std.testing.expectEqual(@as(i32, 3), report.hit_b[0]);
}

test "cena: pedaço solto, massa fora e cauda no chão" {
    var scene = Scene{ .n = 4, .pivot = .{ 0, 0, 0.2 }, .n_att = 2, .att = .{ 0, 12.0 * std.math.pi / 180.0 } };
    scene.parts[0] = boxAt(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem
    scene.parts[1] = boxAt(.{ 0, 0, -0.07 }, .{ 0.12, 0.8, 0.01 }, 1); // asa sobre ela
    scene.parts[2] = boxAt(.{ -1.0, 0, 0 }, .{ 0.1, 0.3, 0.005 }, 2); // EH solta, sem tubo
    scene.parts[3] = .{ .kind = POINT, .owner = 3, .c = .{ 0.1, 0, 0 } }; // bateria na fuselagem
    var report = check(&scene);
    try std.testing.expectEqual(@as(i32, 2), report.n_groups);
    try std.testing.expectEqual(@as(i32, 0), report.n_outside);
    try std.testing.expect(report.ok == 0);
    scene.need_connected = 0; // só contados: parado, o resto passa
    scene.n_att = 1;
    try std.testing.expect(check(&scene).ok == 1 and check(&scene).n_groups == 2);
    scene.need_connected = 1;
    scene.n_att = 2;
    // o tubo liga a EH: uma peça só; girado 12° a EH (a 1,1 m atrás, 0,2 m acima do chão) bate
    scene.parts[4] = boxAt(.{ -0.55, 0, 0 }, .{ 0.45, 0.01, 0.01 }, 4);
    scene.n = 5;
    report = check(&scene);
    try std.testing.expectEqual(@as(i32, 1), report.n_groups);
    try std.testing.expect(report.low[0] > 0 and report.low[1] < 0);
    try std.testing.expectEqual(@as(i32, 2), report.low_part[1]);
    // descendo as rodas o que o relatório pede, a EH passa raspando na rotação
    try std.testing.expect(report.gear_raise > 0);
    var up = scene;
    up.pivot[2] += report.gear_raise + 1e-9;
    const r2 = check(&up);
    try std.testing.expect(r2.ok == 1 and r2.low[1] >= 0 and r2.low[1] < 1e-8 and r2.gear_raise == 0);
    // a bateria fora de tudo
    scene.parts[3].c = .{ 0.1, 0.5, 0.3 };
    report = check(&scene);
    try std.testing.expectEqual(@as(i32, 1), report.n_outside);
    try std.testing.expectEqual(@as(i32, 3), report.outside[0]);
}
