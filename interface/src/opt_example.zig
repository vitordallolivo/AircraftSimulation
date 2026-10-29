//! Dados de exemplo da tela do aeroopt enquanto ela não roda a busca: uma rodada inventada, sempre a mesma (semente
//! fixa), com o formato do que o aeroopt mostra (pontos avaliados, configurações, etapas). Não é resultado de
//! avião nenhum: a nota é uma função suave de envergadura e corda com o máximo conhecido, como o
//! `aeroopt/synthetic.py` do Python.
const std = @import("std");

pub const evaluation_count = 240;
pub const generation_count = 12;
pub const per_generation = evaluation_count / generation_count;

pub const configurations = [_][:0]const u8{ "monoplano, asa alta", "monoplano, asa baixa", "biplano", "tandem", "asa voadora", "monoplano, cauda em V" };

/// quantos aviões passaram em cada etapa (do primeiro ao último)
pub const stages = [_][:0]const u8{ "CONFIGURAÇÕES", "GEOMETRIA", "VOA?", "SUPERFÍCIES", "6GDL", "NOTA" };

pub const Run = struct {
    span: [evaluation_count]f64 = undefined, // envergadura (m)
    chord: [evaluation_count]f64 = undefined, // corda na raiz (m)
    mtow: [evaluation_count]f64 = undefined, // kg
    score: [evaluation_count]f64 = undefined, // nota
    index: [evaluation_count]f64 = undefined, // número da avaliação (eixo x)
    generation_best: [generation_count]f64 = undefined, // melhor nota até a geração
    generation_mean: [generation_count]f64 = undefined,
    generation_axis: [generation_count]f64 = undefined,
    configuration_score: [configurations.len]f64 = undefined, // melhor nota de cada configuração
    stage_count: [stages.len]f64 = undefined,
    best: usize = 0,
};

/// a nota inventada: máximo 100 em b = 2,3 m e c = 0,40 m
pub fn syntheticScore(span: f64, chord: f64) f64 {
    const db = (span - 2.3) / 0.35;
    const dc = (chord - 0.40) / 0.08;
    return 100 * @exp(-0.5 * (db * db + dc * dc + 0.6 * db * dc));
}

/// gera a rodada: cada geração amostra em volta do melhor até ali, com o passo encolhendo
pub fn generate(run: *Run) void {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var best_span: f64 = 1.9;
    var best_chord: f64 = 0.32;
    var best_score: f64 = -1;
    for (0..generation_count) |generation| {
        const shrink = 1.0 - 0.07 * @as(f64, @floatFromInt(generation));
        var total: f64 = 0;
        for (0..per_generation) |k| {
            const i = generation * per_generation + k;
            const span = std.math.clamp(best_span + random.floatNorm(f64) * 0.25 * shrink, 1.6, 2.8);
            const chord = std.math.clamp(best_chord + random.floatNorm(f64) * 0.06 * shrink, 0.25, 0.55);
            const score = syntheticScore(span, chord) * (0.97 + 0.03 * random.float(f64));
            run.span[i] = span;
            run.chord[i] = chord;
            run.score[i] = score;
            run.mtow[i] = 8 + 6 * (span - 1.6) + 9 * (chord - 0.25) + random.floatNorm(f64) * 0.25;
            run.index[i] = @floatFromInt(i + 1);
            total += score;
            if (score > best_score) {
                best_score = score;
                best_span = span;
                best_chord = chord;
                run.best = i;
            }
        }
        run.generation_best[generation] = best_score;
        run.generation_mean[generation] = total / @as(f64, @floatFromInt(per_generation));
        run.generation_axis[generation] = @floatFromInt(generation + 1);
    }
    const factors = [_]f64{ 1.0, 0.86, 0.74, 0.69, 0.52, 0.80 };
    for (&run.configuration_score, factors) |*score, factor| score.* = best_score * factor;
    const passed = [_]f64{ 15, 15, 11, 11, 9, 9 };
    run.stage_count = passed;
}

test "rodada de exemplo: sempre a mesma, o melhor sobe e fica perto do máximo conhecido" {
    var first: Run = .{};
    var second: Run = .{};
    generate(&first);
    generate(&second);
    try std.testing.expectEqualSlices(f64, &first.score, &second.score);
    for (1..generation_count) |g| try std.testing.expect(first.generation_best[g] >= first.generation_best[g - 1]);
    try std.testing.expect(first.generation_best[generation_count - 1] > 90);
    try std.testing.expectEqual(first.score[first.best], first.generation_best[generation_count - 1]);
}
