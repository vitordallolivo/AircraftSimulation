//! As buscas de uma variável só, para quem chama a avaliação por conta própria (uma simulação, uma montagem do
//! avião): cada busca é um estado pequeno que diz qual ponto avaliar e o que fazer com a resposta. Assim a mesma conta
//! serve para quem roda tudo de uma vez e para quem avança um passo por quadro da tela, e nenhum manager tem um laço de
//! busca próprio.
//!
//! - `Bisection`: o intervalo [low, high] em que um lado passa e o outro não; o meio é avaliado e a resposta diz para
//!   que lado ele vai.
//! - `SignBisection`: a raiz de uma função contínua, pela troca de sinal entre as pontas.
//! - `GoldenSection`: o máximo de uma função unimodal pela seção áurea (Kiefer, "Sequential minimax search for a
//!   maximum", Proc. AMS 4, 1953; a conferir no PDF): cada passo reaproveita um dos dois pontos internos.
//! - `secant`: o próximo ponto da secante pela raiz de g a partir de dois pontos (x, g(x)).
const std = @import("std");

/// o intervalo da bisseção; `step` conta quantos meios já foram avaliados
pub const Bisection = struct {
    low: f64,
    high: f64,
    step: usize = 0,

    /// o ponto a avaliar agora
    pub fn middle(bisection: Bisection) f64 {
        return 0.5 * (bisection.low + bisection.high);
    }

    /// a largura do intervalo
    pub fn width(bisection: Bisection) f64 {
        return bisection.high - bisection.low;
    }

    /// o ponto avaliado `at` vira o novo `low` (`raise`) ou o novo `high` (`lower`)
    pub fn move(bisection: *Bisection, at: f64, side: enum { raise, lower }) void {
        switch (side) {
            .raise => bisection.low = at,
            .lower => bisection.high = at,
        }
        bisection.step += 1;
    }
};

/// a bisseção pela troca de sinal: guarda o valor na ponta de baixo
pub const SignBisection = struct {
    interval: Bisection,
    value_low: f64,

    /// a busca entre `low` e `high` com os valores da função nas duas pontas; null se o sinal não troca
    pub fn init(low: f64, high: f64, value_low: f64, value_high: f64) ?SignBisection {
        if ((value_low > 0) == (value_high > 0)) return null;
        return .{ .interval = .{ .low = low, .high = high }, .value_low = value_low };
    }

    /// o ponto a avaliar agora
    pub fn middle(search: SignBisection) f64 {
        return search.interval.middle();
    }

    /// o valor da função no meio `at`: a ponta com o mesmo sinal anda até ele
    pub fn update(search: *SignBisection, at: f64, value: f64) void {
        if ((value > 0) == (search.value_low > 0)) {
            search.interval.move(at, .raise);
            search.value_low = value;
        } else search.interval.move(at, .lower);
    }
};

/// a seção áurea para o máximo: os dois pontos internos e qual deles vai ser avaliado depois de `shrink`
pub const GoldenSection = struct {
    pub const ratio = (@sqrt(5.0) - 1.0) / 2.0;

    low: f64,
    high: f64,
    left: f64,
    right: f64,

    /// os dois pontos internos de [low, high] (os dois precisam ser avaliados antes do primeiro `shrink`)
    pub fn init(low: f64, high: f64) GoldenSection {
        return .{ .low = low, .high = high, .left = high - ratio * (high - low), .right = low + ratio * (high - low) };
    }

    /// o lado que ficou e o ponto novo: com `left_better`, o intervalo encolhe para a esquerda e o ponto novo é o
    /// novo `left` (o antigo `left` virou `right`); senão, o contrário
    pub fn shrink(search: *GoldenSection, left_better: bool) f64 {
        if (left_better) {
            search.high = search.right;
            search.right = search.left;
            search.left = search.high - ratio * (search.high - search.low);
            return search.left;
        }
        search.low = search.left;
        search.left = search.right;
        search.right = search.low + ratio * (search.high - search.low);
        return search.right;
    }
};

/// o próximo x da secante pela raiz de g, a partir de (x0, g0) e (x1, g1); null se g não mudou
pub fn secant(previous: [2]f64, current: [2]f64) ?f64 {
    if (current[1] == previous[1]) return null;
    return current[0] - current[1] * (current[0] - previous[0]) / (current[1] - previous[1]);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "bisseção: √2 pelo lado que passa (x² < 2 sobe o low)" {
    var bisection: Bisection = .{ .low = 0, .high = 2 };
    while (bisection.width() > 1e-12) {
        const at = bisection.middle();
        bisection.move(at, if (at * at < 2) .raise else .lower);
    }
    try testing.expectApproxEqAbs(@sqrt(2.0), bisection.middle(), 1e-12);
    try testing.expect(bisection.step > 30);
}

test "bisseção por sinal: a raiz de cos em [0, 3] é π/2; sem troca de sinal, nada" {
    var search = SignBisection.init(0, 3, @cos(0.0), @cos(3.0)).?;
    for (0..50) |_| {
        const at = search.middle();
        search.update(at, @cos(at));
    }
    try testing.expectApproxEqAbs(std.math.pi / 2.0, search.middle(), 1e-12);
    try testing.expect(SignBisection.init(0, 1, 1, 2) == null);
}

test "seção áurea: o máximo de −(x − 0,3)² em [0, 2]" {
    const value = struct {
        fn of(x: f64) f64 {
            return -(x - 0.3) * (x - 0.3);
        }
    }.of;
    var search = GoldenSection.init(0, 2);
    var left = value(search.left);
    var right = value(search.right);
    for (0..60) |_| {
        const left_better = left >= right;
        const at = search.shrink(left_better);
        if (left_better) {
            right = left;
            left = value(at);
        } else {
            left = right;
            right = value(at);
        }
    }
    try testing.expectApproxEqAbs(@as(f64, 0.3), 0.5 * (search.low + search.high), 1e-9);
}

test "secante: a raiz de x² − 2 a partir de 1 e 2" {
    var previous = [2]f64{ 1, -1 };
    var current = [2]f64{ 2, 2 };
    for (0..20) |_| {
        const x = secant(previous, current) orelse break;
        previous = current;
        current = .{ x, x * x - 2 };
    }
    try testing.expectApproxEqAbs(@sqrt(2.0), current[0], 1e-12);
    try testing.expect(secant(.{ 1, 3 }, .{ 2, 3 }) == null);
}
