//! Trem de pouso: a treliça de tubos como pórtico 3D de elementos finitos (6 graus por nó), as margens de cada tubo e o
//! impacto do pouso num modelo de massa e mola.
//!
//! Estático: cada tubo é uma viga de Euler–Bernoulli 3D (Przemieniecki, "Theory of Matrix Structural Analysis", matriz
//! de rigidez do elemento de pórtico espacial; a conferir no PDF). Os nós presos na fuselagem são engastados, as forças
//! do caso (as do usuário: pouso em três ou dois pontos, atrito, táxi) entram nos nós das rodas, e K u = F dá os
//! deslocamentos. Em cada tubo saem a normal, os cortantes, o torsor e os fletores, e as margens:
//!
//!     σ = |N|/A + M r/I,    τ = T r/(2 I) + 2 V/A,    P_cr = π² E I/(K L)²
//!
//! (Megson, tubos de parede fina; Euler com o fator de comprimento K do usuário.)
//!
//! Impacto: a massa que cai sobre o trem, com o pneu e a perna como molas em série, k = (1/k_pneu + 1/k_perna)⁻¹,
//! amortecimento c = 2 ζ √(k m), um batente mais rígido no fim do curso e a sustentação como uma fração do peso
//! (Currey, "Aircraft Landing Gear Design: Principles and Practices", modelo de um grau; a conferir no PDF). RK4 com o
//! passo do usuário. Sai o fator de carga de pico e se o avião quicou.
const std = @import("std");
const fmath = @import("../math/fmath.zig");
const linalg = @import("../math/linalg.zig");
const section = @import("section.zig");

pub const max_nodes = 16;
pub const max_members = 32;
const dofs_per_node = 6;
const max_dofs = max_nodes * dofs_per_node;

/// um nó: posição (m, corpo), se está preso na fuselagem e a carga do caso (N e N·m, corpo)
pub const Node = extern struct {
    position: [3]f64 = .{ 0, 0, 0 },
    force: [3]f64 = .{ 0, 0, 0 },
    moment: [3]f64 = .{ 0, 0, 0 },
    fixed: i32 = 0,
    _pad: i32 = 0,
};

/// um tubo entre dois nós: material (índice), diâmetros (m) e o fator de comprimento de Euler K
pub const Member = extern struct {
    node_a: i32 = 0,
    node_b: i32 = 0,
    material: i32 = 0,
    _pad: i32 = 0,
    outer: f64 = 0,
    inner: f64 = 0,
    length_factor: f64 = 1,
};

/// os esforços do tubo (o maior entre as duas pontas) e as margens; `buckling` só quando ele está comprimido
pub const MemberResult = extern struct {
    axial: f64 = 0, // N, + tração
    shear: f64 = 0, // N
    torque: f64 = 0, // N·m
    bending: f64 = 0, // N·m
    normal_stress: f64 = 0, // Pa
    shear_stress: f64 = 0, // Pa
    normal_margin: f64 = 0,
    shear_margin: f64 = 0,
    buckling_margin: f64 = 0,
};

pub const Error = error{ TooManyNodes, TooManyMembers, BadNode, BadMaterial, NoSupport, Singular };

const DofMatrix = [max_dofs][max_dofs]f64;

/// a base local do tubo: x ao longo dele; y perpendicular a x e ao z do corpo (ou ao y do corpo se o tubo é vertical)
fn localAxes(from: [3]f64, to: [3]f64) struct { length: f64, axes: [3][3]f64 } {
    const delta = [3]f64{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    const length = @sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]);
    const x = [3]f64{ delta[0] / length, delta[1] / length, delta[2] / length };
    const reference: [3]f64 = if (@abs(x[2]) > 0.95) .{ 0, 1, 0 } else .{ 0, 0, 1 };
    var y = cross(reference, x);
    const norm = @sqrt(y[0] * y[0] + y[1] * y[1] + y[2] * y[2]);
    y = .{ y[0] / norm, y[1] / norm, y[2] / norm };
    return .{ .length = length, .axes = .{ x, y, cross(x, y) } };
}

fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// a rigidez 12 × 12 do pórtico espacial nos eixos locais (u, v, w, θx, θy, θz em cada ponta)
fn localStiffness(modulus: f64, shear_modulus: f64, area: f64, inertia: f64, polar: f64, length: f64) [12][12]f64 {
    var k: [12][12]f64 = [_][12]f64{[_]f64{0} ** 12} ** 12;
    const axial = modulus * area / length;
    const torsion = shear_modulus * polar / length;
    const l2 = length * length;
    const l3 = l2 * length;
    const b12 = 12 * modulus * inertia / l3;
    const b6 = 6 * modulus * inertia / l2;
    const b4 = 4 * modulus * inertia / length;
    const b2 = 2 * modulus * inertia / length;
    k[0][0] = axial;
    k[0][6] = -axial;
    k[6][6] = axial;
    k[3][3] = torsion;
    k[3][9] = -torsion;
    k[9][9] = torsion;
    // flexão no plano x-y (v, θz)
    k[1][1] = b12;
    k[1][5] = b6;
    k[1][7] = -b12;
    k[1][11] = b6;
    k[5][5] = b4;
    k[5][7] = -b6;
    k[5][11] = b2;
    k[7][7] = b12;
    k[7][11] = -b6;
    k[11][11] = b4;
    // flexão no plano x-z (w, θy)
    k[2][2] = b12;
    k[2][4] = -b6;
    k[2][8] = -b12;
    k[2][10] = -b6;
    k[4][4] = b4;
    k[4][8] = b6;
    k[4][10] = b2;
    k[8][8] = b12;
    k[8][10] = b6;
    k[10][10] = b4;
    for (0..12) |i| for (0..i) |j| {
        k[i][j] = k[j][i];
    };
    return k;
}

/// leva um vetor de 12 dos eixos do corpo para os locais (`axes` nas linhas)
fn toLocal(axes: [3][3]f64, global: [12]f64) [12]f64 {
    var out: [12]f64 = undefined;
    for (0..4) |block| {
        for (0..3) |i| {
            out[3 * block + i] = axes[i][0] * global[3 * block] + axes[i][1] * global[3 * block + 1] + axes[i][2] * global[3 * block + 2];
        }
    }
    return out;
}

/// propriedades do tubo: área, I, J (= 2 I) e o raio externo
fn tubeProperties(member: Member) struct { area: f64, inertia: f64, polar: f64, radius: f64 } {
    const tube = section.SectionPart.tube(member.material, member.outer, member.inner, 0);
    return .{ .area = tube.area, .inertia = tube.own_inertia, .polar = 2 * tube.own_inertia, .radius = 0.5 * member.outer };
}

/// resolve o pórtico no caso de carga dos nós e devolve os esforços e as margens de cada tubo em `out`
pub fn solveFrame(materials: []const section.Material, nodes: []const Node, members: []const Member, out: []MemberResult) Error!void {
    if (nodes.len > max_nodes) return error.TooManyNodes;
    if (members.len > max_members) return error.TooManyMembers;
    const dofs = nodes.len * dofs_per_node;
    var stiffness: DofMatrix = undefined;
    for (0..dofs) |i| for (0..dofs) |j| {
        stiffness[i][j] = 0;
    };
    var any_fixed = false;
    for (nodes) |node| any_fixed = any_fixed or node.fixed != 0;
    if (!any_fixed) return error.NoSupport;
    for (members) |member| {
        if (member.node_a < 0 or member.node_b < 0 or member.node_a >= nodes.len or member.node_b >= nodes.len) return error.BadNode;
        if (member.material < 0 or member.material >= materials.len) return error.BadMaterial;
        const material = materials[@intCast(member.material)];
        const tube = tubeProperties(member);
        const a: usize = @intCast(member.node_a);
        const b: usize = @intCast(member.node_b);
        const frame = localAxes(nodes[a].position, nodes[b].position);
        const local = localStiffness(material.modulus, material.shear_modulus, tube.area, tube.inertia, tube.polar, frame.length);
        // K_global = Tᵀ K_local T, com T bloco-diagonal de `axes`
        var global_index: [12]usize = undefined;
        for (0..6) |i| {
            global_index[i] = a * dofs_per_node + i;
            global_index[6 + i] = b * dofs_per_node + i;
        }
        for (0..12) |i| for (0..12) |j| {
            var value: f64 = 0;
            const block_i = i / 3;
            const block_j = j / 3;
            for (0..3) |p| for (0..3) |q| {
                value += frame.axes[p][i % 3] * local[3 * block_i + p][3 * block_j + q] * frame.axes[q][j % 3];
            };
            stiffness[global_index[i]][global_index[j]] += value;
        };
    }
    var displacement: [max_dofs]f64 = undefined;
    for (nodes, 0..) |node, index| {
        for (0..3) |i| {
            displacement[index * dofs_per_node + i] = node.force[i];
            displacement[index * dofs_per_node + 3 + i] = node.moment[i];
        }
        if (node.fixed != 0) {
            // engaste: a linha e a coluna viram a identidade, com o deslocamento zero
            for (0..dofs_per_node) |i| {
                const dof = index * dofs_per_node + i;
                for (0..dofs) |k| {
                    stiffness[dof][k] = 0;
                    stiffness[k][dof] = 0;
                }
                stiffness[dof][dof] = 1;
                displacement[dof] = 0;
            }
        }
    }
    var pivots: [max_dofs]usize = undefined;
    if (!linalg.luFactor(max_dofs, &stiffness, dofs, &pivots)) return error.Singular;
    linalg.luSolve(max_dofs, &stiffness, dofs, &pivots, &displacement);
    for (members, out[0..members.len]) |member, *result| {
        const material = materials[@intCast(member.material)];
        const tube = tubeProperties(member);
        const a: usize = @intCast(member.node_a);
        const b: usize = @intCast(member.node_b);
        const frame = localAxes(nodes[a].position, nodes[b].position);
        var global: [12]f64 = undefined;
        for (0..6) |i| {
            global[i] = displacement[a * dofs_per_node + i];
            global[6 + i] = displacement[b * dofs_per_node + i];
        }
        const local_displacement = toLocal(frame.axes, global);
        const local = localStiffness(material.modulus, material.shear_modulus, tube.area, tube.inertia, tube.polar, frame.length);
        var forces: [12]f64 = [_]f64{0} ** 12;
        for (0..12) |i| for (0..12) |j| {
            forces[i] += local[i][j] * local_displacement[j];
        };
        const axial = forces[6]; // a força na ponta b ao longo de x: + tração
        const shear = @max(@sqrt(forces[1] * forces[1] + forces[2] * forces[2]), @sqrt(forces[7] * forces[7] + forces[8] * forces[8]));
        const torque = @abs(forces[9]);
        const bending = @max(@sqrt(forces[4] * forces[4] + forces[5] * forces[5]), @sqrt(forces[10] * forces[10] + forces[11] * forces[11]));
        const normal_stress = @abs(axial) / tube.area + bending * tube.radius / tube.inertia;
        const shear_stress = torque * tube.radius / tube.polar + 2 * shear / tube.area;
        const allowable = if (axial >= 0) material.tension else material.compression;
        const effective = member.length_factor * frame.length;
        const critical = fmath.pi * fmath.pi * material.modulus * tube.inertia / (effective * effective);
        result.* = .{
            .axial = axial,
            .shear = shear,
            .torque = torque,
            .bending = bending,
            .normal_stress = normal_stress,
            .shear_stress = shear_stress,
            .normal_margin = section.normalMargin(.{ .tension = allowable, .compression = allowable }, normal_stress),
            .shear_margin = section.shearMargin(material, shear_stress),
            .buckling_margin = if (axial < 0) critical / -axial - 1 else std.math.inf(f64),
        };
    }
}

/// o pouso num grau de liberdade: massa (kg), molas (N/m), ζ, curso até o batente (m) e quanto o batente é mais
/// rígido, a sustentação como fração do peso, a velocidade de descida (m/s, + para baixo), o passo e o tempo (s)
pub const Drop = extern struct {
    mass: f64 = 0,
    tire_stiffness: f64 = 0,
    leg_stiffness: f64 = 0,
    damping_ratio: f64 = 0,
    stroke: f64 = 0,
    stopper_ratio: f64 = 10,
    lift_ratio: f64 = 0,
    sink_speed: f64 = 0,
    step: f64 = 5e-4,
    duration: f64 = 0.5,
};

/// o fator de carga de pico (força no trem sobre o peso), o curso máximo (m) e se a roda saiu do chão depois do toque
pub const DropResult = extern struct {
    peak_load_factor: f64 = 0,
    max_compression: f64 = 0,
    bounced: i32 = 0,
    _pad: i32 = 0,
};

/// a força do trem com a compressão `compression` (m, + comprimido) e a velocidade `rate` (m/s)
fn gearForce(drop: Drop, compression: f64, rate: f64) f64 {
    if (compression <= 0) return 0; // no ar: a roda não puxa
    const spring = 1 / (1 / drop.tire_stiffness + 1 / drop.leg_stiffness);
    const damping = 2 * drop.damping_ratio * @sqrt(spring * drop.mass);
    var force = spring * compression + damping * rate;
    if (drop.stroke > 0 and compression > drop.stroke) force += drop.stopper_ratio * spring * (compression - drop.stroke);
    return @max(force, 0);
}

/// integra o pouso por RK4 a partir do toque (compressão zero, descendo a `sink_speed`)
pub fn landing(drop: Drop) DropResult {
    const gravity = 9.80665;
    const weight = drop.mass * gravity;
    var compression: f64 = 0;
    var rate = drop.sink_speed;
    var result: DropResult = .{};
    var touched = false;
    var time: f64 = 0;
    const Derivative = struct { position: f64, velocity: f64 };
    const derivative = struct {
        fn at(settings: Drop, x: f64, v: f64) Derivative {
            const net = settings.mass * 9.80665 * (1 - settings.lift_ratio) - gearForce(settings, x, v);
            return .{ .position = v, .velocity = net / settings.mass };
        }
    }.at;
    while (time < drop.duration) : (time += drop.step) {
        const k1 = derivative(drop, compression, rate);
        const k2 = derivative(drop, compression + 0.5 * drop.step * k1.position, rate + 0.5 * drop.step * k1.velocity);
        const k3 = derivative(drop, compression + 0.5 * drop.step * k2.position, rate + 0.5 * drop.step * k2.velocity);
        const k4 = derivative(drop, compression + drop.step * k3.position, rate + drop.step * k3.velocity);
        compression += drop.step / 6 * (k1.position + 2 * k2.position + 2 * k3.position + k4.position);
        rate += drop.step / 6 * (k1.velocity + 2 * k2.velocity + 2 * k3.velocity + k4.velocity);
        const force = gearForce(drop, compression, rate);
        if (force > 0) touched = true;
        if (touched and compression < 0) result.bounced = 1;
        result.peak_load_factor = @max(result.peak_load_factor, force / weight);
        result.max_compression = @max(result.max_compression, compression);
    }
    return result;
}
