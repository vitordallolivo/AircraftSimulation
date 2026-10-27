//! Otimizações em avaliação (`-Dopt`): cada uma é um bit, desligado por padrão (ver core/OTIMIZACOES.md).
//!
//! O valor de cada campo é o bit dele. O `build.zig` lê este enum para traduzir os nomes de `-Dopt` na soma dos
//! bits, e o código pergunta por nome: `fmath.optOn(.peak)`. Otimização nova = um campo novo com o próximo bit.
pub const Opt = enum(u8) {
    @"noinline" = 1, // SinLut.sincos sem inline forçado: o compilador decide (math/fmath.zig)
    floatmode = 2, // float mode "optimized" nas funções quentes (physics/aero.zig, physics/propulsion.zig)
    logstd = 4, // log (e o log dentro de pow) da std, o resto das tabelas (math/fmath.zig)
    peak = 8, // peakCL por varredura grossa + seção áurea (physics/aero.zig)
    cse = 16, // o painel calcula sigmaStall e sincos(α) uma vez só (physics/aero.zig)
    minimax = 32, // sin/cos por polinômio minimax, sem tabela (math/fmath.zig)
    estrin = 64, // o polinômio do exp por Estrin no lugar do Horner (math/fmath.zig)

    /// o bit da otimização (o mesmo número do campo)
    pub inline fn bit(self: Opt) u8 {
        return @intFromEnum(self);
    }

    /// a otimização `self` está ligada em `bits`?
    pub inline fn in(self: Opt, bits: u8) bool {
        return bits & self.bit() != 0;
    }
};

comptime {
    // cada campo é uma potência de 2 e nenhum se repete (o enum já proíbe valores iguais)
    for (@typeInfo(Opt).@"enum".fields) |field| if (field.value == 0 or field.value & (field.value - 1) != 0)
        @compileError("-Dopt: '" ++ field.name ++ "' não é um bit só");
}
