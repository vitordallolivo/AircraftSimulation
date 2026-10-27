//! Polinômio em duas variáveis de grau N gerado em comptime, na ordem dos ajustes do MATLAB
//! (`poly55`, `poly33`, ...):
//!   p00, p10, p01, p20, p11, p02, p30, p21, p12, p03, ...
//!   P(x, y) = Σ p_ij x^i y^j,  i + j <= N
//! A tabela de expoentes e o laço de avaliação são resolvidos pelo compilador: em tempo de
//! execução sobra só uma sequência de FMAs com as potências calculadas uma vez.
const std = @import("std");

/// o tipo do polinômio de grau `deg` em duas variáveis
pub fn Poly2(comptime deg: u32) type {
    return struct {
        pub const degree = deg;
        pub const n_coef: usize = (deg + 1) * (deg + 2) / 2;

        /// expoentes (i, j) de cada coeficiente, na ordem do MATLAB
        pub const exps: [n_coef][2]u32 = blk: {
            var exponents: [n_coef][2]u32 = undefined;
            var k: usize = 0;
            for (0..deg + 1) |total| {
                for (0..total + 1) |j| {
                    exponents[k] = .{ @intCast(total - j), @intCast(j) };
                    k += 1;
                }
            }
            break :blk exponents;
        };

        /// nomes "p00", "p10", ... (para o esquema e para mensagens)
        pub fn name(comptime index: usize) []const u8 {
            return std.fmt.comptimePrint("p{d}{d}", .{ exps[index][0], exps[index][1] });
        }

        /// P(x, y) com os coeficientes na ordem de `exps`
        pub inline fn eval(coefficients: *const [n_coef]f64, x_value: f64, y_value: f64) f64 {
            var x_powers: [deg + 1]f64 = undefined;
            var y_powers: [deg + 1]f64 = undefined;
            x_powers[0] = 1;
            y_powers[0] = 1;
            inline for (1..deg + 1) |k| {
                x_powers[k] = x_powers[k - 1] * x_value;
                y_powers[k] = y_powers[k - 1] * y_value;
            }
            var sum: f64 = 0;
            inline for (exps, 0..) |exponent, k| sum = @mulAdd(f64, coefficients[k], x_powers[exponent[0]] * y_powers[exponent[1]], sum);
            return sum;
        }

        /// ∂P/∂x (inclinação dT/dV, por exemplo)
        pub inline fn ddx(coefficients: *const [n_coef]f64, x_value: f64, y_value: f64) f64 {
            var x_powers: [deg + 1]f64 = undefined;
            var y_powers: [deg + 1]f64 = undefined;
            x_powers[0] = 1;
            y_powers[0] = 1;
            inline for (1..deg + 1) |k| {
                x_powers[k] = x_powers[k - 1] * x_value;
                y_powers[k] = y_powers[k - 1] * y_value;
            }
            var sum: f64 = 0;
            inline for (exps, 0..) |exponent, k| {
                if (exponent[0] > 0) sum = @mulAdd(f64, coefficients[k] * @as(f64, @floatFromInt(exponent[0])), x_powers[exponent[0] - 1] * y_powers[exponent[1]], sum);
            }
            return sum;
        }
    };
}

const testing = std.testing;

test "ordem dos coeficientes igual ao poly55 do MATLAB" {
    const Poly = Poly2(5);
    try testing.expectEqual(@as(usize, 21), Poly.n_coef);
    const want = [_][]const u8{ "p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03", "p40", "p31", "p22", "p13", "p04", "p50", "p41", "p32", "p23", "p14", "p05" };
    inline for (want, 0..) |expected, k| try testing.expectEqualStrings(expected, Poly.name(k));
}

test "avaliação e derivada" {
    const Poly = Poly2(2); // p00 + p10 x + p01 y + p20 x² + p11 x y + p02 y²
    const coefficients = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const x_value = 0.7;
    const y_value = -1.3;
    try testing.expectApproxEqAbs(1 + 2 * x_value + 3 * y_value + 4 * x_value * x_value + 5 * x_value * y_value + 6 * y_value * y_value, Poly.eval(&coefficients, x_value, y_value), 1e-12);
    try testing.expectApproxEqAbs(2 + 8 * x_value + 5 * y_value, Poly.ddx(&coefficients, x_value, y_value), 1e-12);
}
