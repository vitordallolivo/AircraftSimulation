//! Flutter de uma semiasa: viga de elementos finitos (flexão e torção acopladas pela massa), reduzida aos primeiros
//! modos de vibração, com a aerodinâmica não estacionária de Theodorsen em faixas e o método p-k.
//!
//! Estrutura: cada elemento tem flexão em Hermite cúbico (w e w' nos nós) e torção linear (θ nos nós), com massa
//! consistente. O acoplamento vem do centro de gravidade da seção atrás do eixo elástico por x_α: um ponto a x atrás
//! do eixo sobe w − x θ, então a energia cinética por metro é ½ (m ẇ² − 2 S_α ẇ θ̇ + I_α θ̇²), com S_α = m x_α e
//! I_α = m (r² + x_α²) em torno do eixo (r é o raio de giração em torno do CG). As integrais são por Gauss de 4 pontos
//! (Bisplinghoff, Ashley e Halfman, "Aeroelasticity", viga em flexão e torção; Przemieniecki, "Theory of Matrix
//! Structural Analysis", matrizes de Hermite; a conferir nos PDFs). A raiz é engastada.
//!
//! Aerodinâmica: em cada faixa, a sustentação e o momento de Theodorsen (NACA Report 496, 1935) na frequência ω, com
//! b a semicorda, a a posição do eixo elástico em semicordas a partir do meio da corda (+ para trás) e k = ω b/V. Com
//! h = −w (h para baixo) e α = θ:
//!
//!     L = π ρ b² (ḧ + V α̇ − b a α̈) + 2 π ρ V b C(k) [ḣ + V α + b (½ − a) α̇]
//!     M = π ρ b² [b a ḧ − V b (½ − a) α̇ − b² (⅛ + a²) α̈] + 2 π ρ V b² (a + ½) C(k) [ḣ + V α + b (½ − a) α̇]
//!
//! C(k) pela aproximação de R. T. Jones (NACA Report 681, 1940; a conferir no PDF):
//! C(k) ≈ 1 − 0,165/(1 − 0,0455 i/k) − 0,335/(1 − 0,3 i/k).
//!
//! p-k (Hassig, Journal of Aircraft 8(11), 1971; a conferir): nos modos normalizados pela massa, ẍ + (Ω² − Q_R) x −
//! (Q_I/ω) ẋ = 0, com Q = Q_R + i Q_I avaliado na frequência ω do próprio modo. Para cada V e cada modo, itera ω até
//! a parte imaginária do autovalor bater com ela. O flutter é a menor V em que o amortecimento de um modo troca de sinal.
const std = @import("std");
const fmath = @import("../math/fmath.zig");
const linalg = @import("../math/linalg.zig");

const Complex = std.math.Complex(f64);

pub const max_elements = 16;
pub const max_modes = 8;
const dofs_per_node = 3; // w, w', θ
const max_dofs = max_elements * dofs_per_node;
const max_states = 2 * max_modes;

/// um elemento da viga, de `start` a `end` (m da raiz): EI e GJ (N·m²), massa por metro (kg/m), CG atrás do eixo
/// elástico (m), raio de giração em torno do CG (m), corda (m) e o eixo elástico em semicordas do meio da corda (+ para
/// trás, o `a` de Theodorsen)
pub const Element = extern struct {
    start: f64 = 0,
    end: f64 = 0,
    bending_stiffness: f64 = 0,
    torsional_stiffness: f64 = 0,
    mass: f64 = 0,
    cg_offset: f64 = 0,
    gyration: f64 = 0,
    chord: f64 = 0,
    axis: f64 = 0,
};

/// a frequência (rad/s) e o amortecimento (ζ = −Re s/|s|) de um modo numa velocidade
pub const ModePoint = extern struct {
    frequency: f64 = 0,
    damping: f64 = 0,
};

/// o flutter: a velocidade (m/s), a frequência (rad/s) e o modo; `found` = 0 se nenhum modo perdeu amortecimento
pub const FlutterResult = extern struct {
    speed: f64 = 0,
    frequency: f64 = 0,
    mode: i32 = -1,
    found: i32 = 0,
};

pub const Error = error{ TooManyElements, TooManyModes, NoElements, NotPositive, NoConvergence };

const DofMatrix = [max_dofs][max_dofs]f64;
const ModeMatrix = [max_modes][max_modes]f64;

/// os modos de vibração da viga: frequências (rad/s) e formas normalizadas pela massa (colunas de `shapes`)
pub const Modes = struct {
    count: usize = 0,
    dofs: usize = 0,
    frequency: [max_modes]f64 = undefined,
    shapes: [max_dofs][max_modes]f64 = undefined,
};

/// pontos e pesos de Gauss de 4 pontos em [0, 1]
const gauss_points = [4]f64{ 0.5 - 0.5 * 0.8611363115940526, 0.5 - 0.5 * 0.3399810435848563, 0.5 + 0.5 * 0.3399810435848563, 0.5 + 0.5 * 0.8611363115940526 };
const gauss_weights = [4]f64{ 0.5 * 0.3478548451374538, 0.5 * 0.6521451548625461, 0.5 * 0.6521451548625461, 0.5 * 0.3478548451374538 };

/// funções de forma no ponto `xi` ∈ [0, 1] de um elemento de comprimento `length`: Hermite (w1, w1', w2, w2') e
/// suas segundas derivadas em x, e as lineares da torção (θ1, θ2)
fn shape(xi: f64, length: f64) struct { bending: [4]f64, curvature: [4]f64, torsion: [2]f64 } {
    const xi2 = xi * xi;
    const xi3 = xi2 * xi;
    return .{
        .bending = .{ 1 - 3 * xi2 + 2 * xi3, length * (xi - 2 * xi2 + xi3), 3 * xi2 - 2 * xi3, length * (xi3 - xi2) },
        .curvature = .{ (-6 + 12 * xi) / (length * length), (-4 + 6 * xi) / length, (6 - 12 * xi) / (length * length), (6 * xi - 2) / length },
        .torsion = .{ 1 - xi, xi },
    };
}

/// os índices globais (na viga com a raiz engastada) dos 6 graus do elemento `index`: (w, w', θ) do nó de dentro e do
/// de fora; null quando o grau é o da raiz
fn elementDofs(index: usize) [6]?usize {
    var out: [6]?usize = undefined;
    for (0..2) |node_side| {
        const node = index + node_side;
        for (0..dofs_per_node) |local| {
            out[node_side * dofs_per_node + local] = if (node == 0) null else (node - 1) * dofs_per_node + local;
        }
    }
    return out;
}

/// os 6 graus do elemento na ordem (w1, w1', θ1, w2, w2', θ2) a partir das funções de forma: o vetor de w e o de θ
fn interpolation(form: anytype) struct { w: [6]f64, theta: [6]f64 } {
    return .{
        .w = .{ form.bending[0], form.bending[1], 0, form.bending[2], form.bending[3], 0 },
        .theta = .{ 0, 0, form.torsion[0], 0, 0, form.torsion[1] },
    };
}

/// monta K e M da viga em `stiffness` e `mass`; devolve o número de graus livres
fn assemble(elements: []const Element, stiffness: *DofMatrix, mass: *DofMatrix) Error!usize {
    if (elements.len == 0) return error.NoElements;
    if (elements.len > max_elements) return error.TooManyElements;
    const dofs = elements.len * dofs_per_node;
    for (0..dofs) |i| for (0..dofs) |j| {
        stiffness[i][j] = 0;
        mass[i][j] = 0;
    };
    for (elements, 0..) |element, index| {
        const length = element.end - element.start;
        if (!(length > 0) or !(element.bending_stiffness > 0) or !(element.torsional_stiffness > 0) or !(element.mass > 0)) return error.NotPositive;
        const static_moment = element.mass * element.cg_offset;
        const inertia = element.mass * (element.gyration * element.gyration + element.cg_offset * element.cg_offset);
        const global = elementDofs(index);
        for (gauss_points, gauss_weights) |xi, weight| {
            const form = shape(xi, length);
            const vectors = interpolation(form);
            const curvature = [6]f64{ form.curvature[0], form.curvature[1], 0, form.curvature[2], form.curvature[3], 0 };
            const twist_rate = [6]f64{ 0, 0, -1 / length, 0, 0, 1 / length };
            for (0..6) |a| {
                const row = global[a] orelse continue;
                for (0..6) |b| {
                    const col = global[b] orelse continue;
                    const scale = weight * length;
                    stiffness[row][col] += scale * (element.bending_stiffness * curvature[a] * curvature[b] + element.torsional_stiffness * twist_rate[a] * twist_rate[b]);
                    mass[row][col] += scale * (element.mass * vectors.w[a] * vectors.w[b] + inertia * vectors.theta[a] * vectors.theta[b] -
                        static_moment * (vectors.w[a] * vectors.theta[b] + vectors.theta[a] * vectors.w[b]));
                }
            }
        }
    }
    return dofs;
}

/// os `count` primeiros modos de vibração: M = L Lᵀ, autovalores de L⁻¹ K L⁻ᵀ (Jacobi) e as formas L⁻ᵀ y
pub fn modes(elements: []const Element, count: usize) Error!Modes {
    if (count > max_modes) return error.TooManyModes;
    var stiffness: DofMatrix = undefined;
    var mass: DofMatrix = undefined;
    const dofs = try assemble(elements, &stiffness, &mass);
    if (!linalg.cholesky(max_dofs, &mass, dofs)) return error.NotPositive;
    // L⁻¹ K L⁻ᵀ: primeiro X = L⁻¹ K (colunas), depois (L⁻¹ Xᵀ)ᵀ
    for (0..dofs) |col| forwardSolve(&mass, dofs, &stiffness, col);
    var reduced: DofMatrix = undefined;
    for (0..dofs) |i| for (0..dofs) |j| {
        reduced[i][j] = stiffness[j][i];
    };
    for (0..dofs) |col| forwardSolve(&mass, dofs, &reduced, col);
    var values: [max_dofs]f64 = undefined;
    var vectors: DofMatrix = undefined;
    linalg.symEigen(max_dofs, &reduced, dofs, &values, &vectors);
    var order: [max_dofs]usize = undefined;
    for (0..dofs) |i| order[i] = i;
    std.mem.sort(usize, order[0..dofs], &values, struct {
        fn less(eigenvalues: *const [max_dofs]f64, left: usize, right: usize) bool {
            return eigenvalues[left] < eigenvalues[right];
        }
    }.less);
    var out: Modes = .{ .count = @min(count, dofs), .dofs = dofs };
    for (0..out.count) |mode| {
        const pick = order[mode];
        out.frequency[mode] = @sqrt(@max(values[pick], 0));
        // L⁻ᵀ y: substituição para trás com Lᵀ
        var row = dofs;
        while (row > 0) {
            row -= 1;
            var sum = vectors[row][pick];
            for (row + 1..dofs) |k| sum -= mass[k][row] * out.shapes[k][mode];
            out.shapes[row][mode] = sum / mass[row][row];
        }
    }
    return out;
}

/// L x = coluna `col` de `target`, no lugar (L no triângulo de baixo de `factor`)
fn forwardSolve(factor: *const DofMatrix, size: usize, target: *DofMatrix, col: usize) void {
    for (0..size) |i| {
        var sum = target[i][col];
        for (0..i) |k| sum -= factor[i][k] * target[k][col];
        target[i][col] = sum / factor[i][i];
    }
}

/// C(k) de Theodorsen pela aproximação de Jones
pub fn theodorsen(reduced_frequency: f64) Complex {
    if (reduced_frequency <= 0) return Complex.init(1, 0);
    const one = Complex.init(1, 0);
    const first = Complex.init(0.165, 0).div(Complex.init(1, -0.0455 / reduced_frequency));
    const second = Complex.init(0.335, 0).div(Complex.init(1, -0.3 / reduced_frequency));
    return one.sub(first).sub(second);
}

/// a matriz aerodinâmica 2 × 2 por metro de uma faixa na frequência `omega`: (L, M) = A (w, θ), complexa
fn stripMatrix(element: Element, density: f64, speed: f64, omega: f64) [2][2]Complex {
    const semichord = 0.5 * element.chord;
    const a = element.axis;
    const theodorsen_value = theodorsen(omega * semichord / speed);
    const pi_rho = fmath.pi * density;
    const omega2 = omega * omega;
    const io = Complex.init(0, omega);
    const circulation = Complex.init(2 * pi_rho * speed * semichord, 0).mul(theodorsen_value);
    // a velocidade normal de 3/4 da corda por unidade de w e de θ: ḣ + V α + b (½ − a) α̇
    const downwash_w = io.neg(); // ḣ = −i ω w
    const downwash_theta = Complex.init(speed, 0).add(io.mul(Complex.init(semichord * (0.5 - a), 0)));
    const lift_w = Complex.init(pi_rho * semichord * semichord * omega2, 0).add(circulation.mul(downwash_w));
    const lift_theta = Complex.init(pi_rho * semichord * semichord * semichord * a * omega2, 0)
        .add(Complex.init(0, pi_rho * semichord * semichord * speed * omega))
        .add(circulation.mul(downwash_theta));
    const arm = Complex.init(semichord * (a + 0.5), 0);
    const moment_w = Complex.init(pi_rho * semichord * semichord * semichord * a * omega2, 0).add(circulation.mul(arm).mul(downwash_w));
    const moment_theta = Complex.init(pi_rho * semichord * semichord * semichord * semichord * (0.125 + a * a) * omega2, 0)
        .add(Complex.init(0, -pi_rho * semichord * semichord * semichord * speed * (0.5 - a) * omega))
        .add(circulation.mul(arm).mul(downwash_theta));
    return .{ .{ lift_w, lift_theta }, .{ moment_w, moment_theta } };
}

/// Q(ω) nos modos: Φᵀ (∫ Nᵀ A N dy) Φ, partes real e imaginária
fn modalAero(elements: []const Element, found: *const Modes, density: f64, speed: f64, omega: f64, real: *ModeMatrix, imaginary: *ModeMatrix) void {
    for (0..found.count) |i| for (0..found.count) |j| {
        real[i][j] = 0;
        imaginary[i][j] = 0;
    };
    for (elements, 0..) |element, index| {
        const length = element.end - element.start;
        const strip = stripMatrix(element, density, speed, omega);
        const global = elementDofs(index);
        for (gauss_points, gauss_weights) |xi, weight| {
            const vectors = interpolation(shape(xi, length));
            // w e θ de cada modo nesse ponto
            var mode_w: [max_modes]f64 = [_]f64{0} ** max_modes;
            var mode_theta: [max_modes]f64 = [_]f64{0} ** max_modes;
            for (0..6) |a| {
                const dof = global[a] orelse continue;
                for (0..found.count) |mode| {
                    mode_w[mode] += vectors.w[a] * found.shapes[dof][mode];
                    mode_theta[mode] += vectors.theta[a] * found.shapes[dof][mode];
                }
            }
            for (0..found.count) |i| for (0..found.count) |j| {
                const force = strip[0][0].mul(Complex.init(mode_w[j], 0)).add(strip[0][1].mul(Complex.init(mode_theta[j], 0)));
                const moment = strip[1][0].mul(Complex.init(mode_w[j], 0)).add(strip[1][1].mul(Complex.init(mode_theta[j], 0)));
                const work = force.mul(Complex.init(mode_w[i], 0)).add(moment.mul(Complex.init(mode_theta[i], 0)));
                real[i][j] += weight * length * work.re;
                imaginary[i][j] += weight * length * work.im;
            };
        }
    }
}

/// o p-k numa velocidade: frequência e amortecimento de cada modo em `out`. Se `out` já traz a frequência de cada modo
/// na velocidade anterior (continuação), ela é o chute; com zero, o chute é a frequência estrutural
pub fn pk(elements: []const Element, found: *const Modes, density: f64, speed: f64, out: []ModePoint) Error!void {
    const count = found.count;
    for (0..count) |mode| {
        var omega = @max(if (out[mode].frequency > 0) out[mode].frequency else found.frequency[mode], 1e-3);
        var point: ModePoint = .{};
        for (0..60) |_| {
            var real: ModeMatrix = undefined;
            var imaginary: ModeMatrix = undefined;
            modalAero(elements, found, density, speed, omega, &real, &imaginary);
            var state: [max_states][max_states]f64 = undefined;
            for (0..2 * count) |i| for (0..2 * count) |j| {
                state[i][j] = 0;
            };
            for (0..count) |i| {
                state[i][count + i] = 1;
                for (0..count) |j| {
                    const structural = if (i == j) found.frequency[i] * found.frequency[i] else 0;
                    state[count + i][j] = -(structural - real[i][j]);
                    state[count + i][count + j] = imaginary[i][j] / omega;
                }
            }
            var eigen_real: [max_states]f64 = undefined;
            var eigen_imag: [max_states]f64 = undefined;
            if (!linalg.generalEigen(max_states, &state, 2 * count, &eigen_real, &eigen_imag)) return error.NoConvergence;
            // o autovalor de parte imaginária positiva mais perto de ω
            var best: ?usize = null;
            for (0..2 * count) |k| {
                if (eigen_imag[k] <= 0) continue;
                if (best == null or @abs(eigen_imag[k] - omega) < @abs(eigen_imag[best.?] - omega)) best = k;
            }
            const pick = best orelse break; // o modo virou real (divergência): sem frequência
            const magnitude = @sqrt(eigen_real[pick] * eigen_real[pick] + eigen_imag[pick] * eigen_imag[pick]);
            point = .{ .frequency = eigen_imag[pick], .damping = -eigen_real[pick] / magnitude };
            if (@abs(eigen_imag[pick] - omega) < 1e-6 * omega) break;
            omega = eigen_imag[pick];
        }
        out[mode] = point;
    }
}

/// a velocidade de flutter entre as velocidades `speeds` (em ordem crescente): a primeira em que o amortecimento de
/// algum modo troca de sinal, interpolada entre os dois pontos; `modes_count` modos
pub fn flutter(elements: []const Element, modes_count: usize, density: f64, speeds: []const f64) Error!FlutterResult {
    const found = try modes(elements, modes_count);
    var previous: [max_modes]ModePoint = [_]ModePoint{.{}} ** max_modes;
    var current: [max_modes]ModePoint = [_]ModePoint{.{}} ** max_modes;
    for (speeds, 0..) |speed, index| {
        try pk(elements, &found, density, speed, current[0..found.count]);
        if (index > 0) {
            for (0..found.count) |mode| {
                const before = previous[mode].damping;
                const after = current[mode].damping;
                if (before > 0 and after <= 0) {
                    const share = before / (before - after);
                    return .{
                        .speed = speeds[index - 1] + share * (speed - speeds[index - 1]),
                        .frequency = previous[mode].frequency + share * (current[mode].frequency - previous[mode].frequency),
                        .mode = @intCast(mode),
                        .found = 1,
                    };
                }
            }
        }
        previous = current;
    }
    return .{};
}

// ------------------------------------------------------------------ testes
const testing = std.testing;
const plot = @import("../util/plot.zig");

/// uma viga uniforme de `length` m em `count` elementos com as propriedades de `element`
fn uniformBeam(comptime count: usize, length: f64, element: Element) [count]Element {
    var out: [count]Element = undefined;
    for (&out, 0..) |*piece, i| {
        piece.* = element;
        piece.start = length * @as(f64, @floatFromInt(i)) / @as(f64, count);
        piece.end = length * @as(f64, @floatFromInt(i + 1)) / @as(f64, count);
    }
    return out;
}

test "flutter: viga em balanço uniforme sem acoplamento dá as frequências fechadas de flexão e torção" {
    // flexão: ω1 = 1,8751² √(EI/(m L⁴)); torção: ω1 = (π/2) √(GJ/(I_α L²)) (Meirovitch, "Elements of Vibration
    // Analysis", viga em balanço; a conferir no PDF)
    const beam = uniformBeam(12, 2, .{ .bending_stiffness = 400, .torsional_stiffness = 60, .mass = 1.5, .gyration = 0.05, .chord = 0.3 });
    const found = try modes(&beam, 4);
    const bending = 1.8751 * 1.8751 * @sqrt(400.0 / (1.5 * 16.0));
    const torsion = fmath.pi / 2.0 * @sqrt(60.0 / (1.5 * 0.05 * 0.05 * 4.0));
    try testing.expectApproxEqRel(bending, found.frequency[0], 1e-3);
    var closest: f64 = std.math.inf(f64);
    for (found.frequency[0..found.count]) |frequency| closest = @min(closest, @abs(frequency - torsion) / torsion);
    try testing.expect(closest < 1e-3);
}

test "flutter: a asa de Goland flutua perto de 137 m/s e 70 rad/s" {
    // a asa de Goland (Goland, Journal of the Aeronautical Sciences 12(4), 1945; dados como em Patil, Hodges e Cesnik,
    // Journal of Aircraft 38(1), 2001, a conferir no PDF): semienvergadura 6,096 m, corda 1,8288 m, eixo elástico a 33 %
    // e CG a 43 % da corda, m = 35,71 kg/m, I = 8,64 kg·m em torno do eixo elástico, EI = 9,77e6 e GJ = 0,987e6 N·m².
    // Patil et al. dão os modos 49,6, 97,0 e 248,9 rad/s e o flutter em 137 m/s com 70,7 rad/s
    const chord = 1.8288;
    const beam = uniformBeam(12, 6.096, .{
        .bending_stiffness = 9.77e6,
        .torsional_stiffness = 0.987e6,
        .mass = 35.71,
        .cg_offset = 0.10 * chord,
        .gyration = @sqrt(8.64 / 35.71 - 0.10 * chord * 0.10 * chord), // I em torno do CG = I_EA − m x_α²
        .chord = chord,
        .axis = (0.33 - 0.5) / 0.5,
    });
    var speeds: [60]f64 = undefined;
    for (&speeds, 0..) |*speed, i| speed.* = 40 + 2.5 * @as(f64, @floatFromInt(i));
    const vibration = try modes(&beam, 3);
    for ([_]f64{ 49.6, 97.0, 248.9 }, vibration.frequency[0..3]) |expected, frequency| try testing.expectApproxEqRel(expected, frequency, 0.04);
    const found = try flutter(&beam, 4, 1.225, &speeds);
    try testing.expectEqual(@as(i32, 1), found.found);
    try testing.expectApproxEqRel(@as(f64, 137), found.speed, 0.02);
    try testing.expectApproxEqRel(@as(f64, 70.7), found.frequency, 0.03);
    // o V-g: frequência e amortecimento dos dois primeiros modos
    const shapes = try modes(&beam, 4);
    var damping: [2][60]f64 = undefined;
    var frequency: [2][60]f64 = undefined;
    var points: [max_modes]ModePoint = [_]ModePoint{.{}} ** max_modes;
    for (speeds, 0..) |speed, i| {
        try pk(&beam, &shapes, 1.225, speed, points[0..shapes.count]);
        for (0..2) |mode| {
            damping[mode][i] = points[mode].damping;
            frequency[mode][i] = points[mode].frequency;
        }
    }
    try plot.fromTest("flutter_goland_amortecimento", .{ .title = "Asa de Goland: V-g", .x_label = "V (m/s)", .y_label = "ζ", .series = &.{
        .{ .label = "modo 1 (flexão)", .x = &speeds, .y = &damping[0] },
        .{ .label = "modo 2 (torção)", .x = &speeds, .y = &damping[1] },
    } });
    try plot.fromTest("flutter_goland_frequencia", .{ .title = "Asa de Goland: V-ω", .x_label = "V (m/s)", .y_label = "ω (rad/s)", .series = &.{
        .{ .label = "modo 1 (flexão)", .x = &speeds, .y = &frequency[0] },
        .{ .label = "modo 2 (torção)", .x = &speeds, .y = &frequency[1] },
    } });
}

test "flutter: C(k) de Jones vale 1 em k = 0 e tende a 1/2 com k grande" {
    try testing.expectApproxEqRel(@as(f64, 1), theodorsen(0).re, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 0.5), theodorsen(1e6).re, 1e-4);
    // em k = 0,1 a tabela de Theodorsen dá C ≈ 0,832 − 0,172 i; a de Jones erra ~0,5 % na parte real e ~6 % na imaginária
    const value = theodorsen(0.1);
    try testing.expectApproxEqRel(@as(f64, 0.832), value.re, 0.01);
    try testing.expectApproxEqRel(@as(f64, -0.172), value.im, 0.07);
}
