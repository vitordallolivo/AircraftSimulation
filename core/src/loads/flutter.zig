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

/// o p-k numa velocidade: frequência e amortecimento de cada modo em `out`
pub fn pk(elements: []const Element, found: *const Modes, density: f64, speed: f64, out: []ModePoint) Error!void {
    const count = found.count;
    for (0..count) |mode| {
        var omega = @max(found.frequency[mode], 1e-3);
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
    var previous: [max_modes]ModePoint = undefined;
    var current: [max_modes]ModePoint = undefined;
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
