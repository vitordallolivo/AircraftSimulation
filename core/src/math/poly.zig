//! Polinômio em duas variáveis de grau N gerado em comptime, na ordem dos ajustes do MATLAB
//! (`poly55`, `poly33`, ...):
//!   p00, p10, p01, p20, p11, p02, p30, p21, p12, p03, ...
//!   P(x, y) = Σ p_ij x^i y^j,  i + j <= N
//! A tabela de expoentes e o laço de avaliação são resolvidos pelo compilador: em tempo de
//! execução sobra só uma sequência de FMAs com as potências calculadas uma vez.
const std = @import("std");

pub fn Poly2(comptime deg: u32) type {
    return struct {
        pub const degree = deg;
        pub const n_coef: usize = (deg + 1) * (deg + 2) / 2;

        /// expoentes (i, j) de cada coeficiente, na ordem do MATLAB
        pub const exps: [n_coef][2]u32 = blk: {
            var e: [n_coef][2]u32 = undefined;
            var k: usize = 0;
            for (0..deg + 1) |total| {
                for (0..total + 1) |j| {
                    e[k] = .{ @intCast(total - j), @intCast(j) };
                    k += 1;
                }
            }
            break :blk e;
        };

        /// nomes "p00", "p10", ... (para o esquema e para mensagens)
        pub fn name(comptime k: usize) []const u8 {
            return std.fmt.comptimePrint("p{d}{d}", .{ exps[k][0], exps[k][1] });
        }

        pub inline fn eval(c: *const [n_coef]f64, x: f64, y: f64) f64 {
            var xp: [deg + 1]f64 = undefined;
            var yp: [deg + 1]f64 = undefined;
            xp[0] = 1;
            yp[0] = 1;
            inline for (1..deg + 1) |k| {
                xp[k] = xp[k - 1] * x;
                yp[k] = yp[k - 1] * y;
            }
            var s: f64 = 0;
            inline for (exps, 0..) |e, k| s = @mulAdd(f64, c[k], xp[e[0]] * yp[e[1]], s);
            return s;
        }

        /// derivada em x (inclinação dT/dV, por exemplo)
        pub inline fn ddx(c: *const [n_coef]f64, x: f64, y: f64) f64 {
            var xp: [deg + 1]f64 = undefined;
            var yp: [deg + 1]f64 = undefined;
            xp[0] = 1;
            yp[0] = 1;
            inline for (1..deg + 1) |k| {
                xp[k] = xp[k - 1] * x;
                yp[k] = yp[k - 1] * y;
            }
            var s: f64 = 0;
            inline for (exps, 0..) |e, k| {
                if (e[0] > 0) s = @mulAdd(f64, c[k] * @as(f64, @floatFromInt(e[0])), xp[e[0] - 1] * yp[e[1]], s);
            }
            return s;
        }
    };
}

const testing = std.testing;

test "ordem dos coeficientes igual ao poly55 do MATLAB" {
    const P = Poly2(5);
    try testing.expectEqual(@as(usize, 21), P.n_coef);
    const want = [_][]const u8{ "p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03", "p40", "p31", "p22", "p13", "p04", "p50", "p41", "p32", "p23", "p14", "p05" };
    inline for (want, 0..) |w, k| try testing.expectEqualStrings(w, P.name(k));
}

test "avaliação e derivada" {
    const P = Poly2(2); // p00 + p10 x + p01 y + p20 x² + p11 x y + p02 y²
    const c = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const x = 0.7;
    const y = -1.3;
    try testing.expectApproxEqAbs(1 + 2 * x + 3 * y + 4 * x * x + 5 * x * y + 6 * y * y, P.eval(&c, x, y), 1e-12);
    try testing.expectApproxEqAbs(2 + 8 * x + 5 * y, P.ddx(&c, x, y), 1e-12);
}
