//! Fuzzing dos módulos.
//!
//! Cada módulo escreve `fn fuzzX(ctx, src: *fuzz.Src) !void` e chama `fuzz.check(ctx, fuzzX, .{})`
//! num teste. `check` roda a função:
//!   1. pelo `std.testing.fuzz` do Zig (com o fuzzer de verdade: `zig build test --fuzz`);
//!   2. com N entradas aleatórias — `zig build test -Dfuzz=N -Dseed=S` (padrão 2000, semente 1).
//!      A semente e a iteração saem no erro, para repetir o caso.
//!
//! (O `--fuzz` do Zig 0.16.0 não compila o executor de testes; o item 2 cobre enquanto isso.)
const std = @import("std");
const opts = @import("build_options");
const Smith = std.testing.Smith;

/// de onde vêm os valores: o fuzzer do Zig (Smith) ou um gerador pseudoaleatório
pub const Src = struct {
    smith: ?*Smith = null,
    rnd: ?std.Random = null,

    pub fn int(s: *Src, comptime T: type, lo: T, hi: T) T {
        if (s.smith) |m| return m.valueRangeAtMost(T, lo, hi);
        return s.rnd.?.intRangeAtMost(T, lo, hi);
    }
    pub fn boolean(s: *Src) bool {
        if (s.smith) |m| return m.value(bool);
        return s.rnd.?.boolean();
    }
    /// verdadeiro com chance 1 / n
    pub fn chance(s: *Src, n: u32) bool {
        return s.int(u32, 1, n) == 1;
    }
    pub fn index(s: *Src, len: usize) usize {
        return @intCast(s.int(u32, 0, @intCast(len - 1)));
    }
    /// número na faixa [lo, hi]
    pub fn range(s: *Src, lo: f64, hi: f64) f64 {
        return lo + (hi - lo) * @as(f64, @floatFromInt(s.int(u16, 0, 65535))) / 65535.0;
    }
    /// qualquer f32 (NaN, ±inf, subnormais e enormes inclusive)
    pub fn any(s: *Src) f64 {
        return @floatCast(@as(f32, @bitCast(s.int(u32, 0, std.math.maxInt(u32)))));
    }
    /// quase sempre válido em [lo, hi]; 1 em 12, um valor qualquer (passa pelo caminho que
    /// funciona e também pelos erros)
    pub fn mostly(s: *Src, lo: f64, hi: f64) f64 {
        return if (s.chance(12)) s.any() else s.range(lo, hi);
    }
    /// enche um pedaço de `buf` com bytes quaisquer; devolve o tamanho
    pub fn bytes(s: *Src, buf: []u8) usize {
        if (s.smith) |m| return m.slice(buf);
        const n = s.rnd.?.uintAtMost(usize, buf.len);
        s.rnd.?.bytes(buf[0..n]);
        return n;
    }
};

pub fn check(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *Src) anyerror!void,
    options: std.testing.FuzzInputOptions,
) !void {
    const W = struct {
        fn f(c: @TypeOf(context), m: *Smith) anyerror!void {
            var src: Src = .{ .smith = m };
            return testOne(c, &src);
        }
    };
    try std.testing.fuzz(context, W.f, options);
    var prng = std.Random.DefaultPrng.init(opts.fuzz_seed);
    for (0..opts.fuzz_iterations) |it| {
        var src: Src = .{ .rnd = prng.random() };
        testOne(context, &src) catch |e| {
            std.debug.print("fuzz: falhou na iteração {d} (semente {d}): {s}\n", .{ it, opts.fuzz_seed, @errorName(e) });
            return e;
        };
    }
}
