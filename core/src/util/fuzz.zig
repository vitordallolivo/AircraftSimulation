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

    /// inteiro em [lo, hi]
    pub fn int(self: *Src, comptime Int: type, lo: Int, hi: Int) Int {
        if (self.smith) |smith| return smith.valueRangeAtMost(Int, lo, hi);
        return self.rnd.?.intRangeAtMost(Int, lo, hi);
    }
    /// verdadeiro ou falso
    pub fn boolean(self: *Src) bool {
        if (self.smith) |smith| return smith.value(bool);
        return self.rnd.?.boolean();
    }
    /// verdadeiro com chance 1 / one_in
    pub fn chance(self: *Src, one_in: u32) bool {
        return self.int(u32, 1, one_in) == 1;
    }
    /// índice válido de uma lista de `len` itens
    pub fn index(self: *Src, len: usize) usize {
        return @intCast(self.int(u32, 0, @intCast(len - 1)));
    }
    /// número na faixa [lo, hi]
    pub fn range(self: *Src, lo: f64, hi: f64) f64 {
        return lo + (hi - lo) * @as(f64, @floatFromInt(self.int(u16, 0, 65535))) / 65535.0;
    }
    /// qualquer f32 (NaN, ±inf, subnormais e enormes inclusive)
    pub fn any(self: *Src) f64 {
        return @floatCast(@as(f32, @bitCast(self.int(u32, 0, std.math.maxInt(u32)))));
    }
    /// quase sempre válido em [lo, hi]; 1 em 12, um valor qualquer (passa pelo caminho que
    /// funciona e também pelos erros)
    pub fn mostly(self: *Src, lo: f64, hi: f64) f64 {
        return if (self.chance(12)) self.any() else self.range(lo, hi);
    }
    /// enche um pedaço de `buf` com bytes quaisquer; devolve o tamanho
    pub fn bytes(self: *Src, buf: []u8) usize {
        if (self.smith) |smith| return smith.slice(buf);
        const count = self.rnd.?.uintAtMost(usize, buf.len);
        self.rnd.?.bytes(buf[0..count]);
        return count;
    }
};

/// roda `testOne` pelo fuzzer do Zig e com N entradas aleatórias (-Dfuzz, -Dseed)
pub fn check(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *Src) anyerror!void,
    options: std.testing.FuzzInputOptions,
) !void {
    return checkScaled(context, testOne, options, 1);
}

/// para casos caros (ex.: cada caso monta e calibra uma simulação): N / `divide` entradas
pub fn checkScaled(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *Src) anyerror!void,
    options: std.testing.FuzzInputOptions,
    divide: usize,
) !void {
    const Wrapper = struct {
        fn run(ctx: @TypeOf(context), smith: *Smith) anyerror!void {
            var src: Src = .{ .smith = smith };
            return testOne(ctx, &src);
        }
    };
    try std.testing.fuzz(context, Wrapper.run, options);
    var prng = std.Random.DefaultPrng.init(opts.fuzz_seed);
    for (0..@max(opts.fuzz_iterations / @max(divide, 1), 1)) |it| {
        var src: Src = .{ .rnd = prng.random() };
        testOne(context, &src) catch |err| {
            std.debug.print("fuzz: falhou na iteração {d} (semente {d}): {s}\n", .{ it, opts.fuzz_seed, @errorName(err) });
            return err;
        };
    }
}
