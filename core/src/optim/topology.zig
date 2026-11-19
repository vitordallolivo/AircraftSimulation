//! A árvore de topologias: uma busca só para várias configurações do avião (as da tabela de asas do projeto, de
//! forma genérica: o núcleo não sabe o que cada uma é). O vetor de projeto começa com um gene que escolhe a
//! configuração, e as variáveis de cada configuração ficam juntas, num trecho dele. Só o trecho da configuração
//! escolhida vale; os outros seguem na população sem custo, para uma troca de configuração pelo cruzamento cair num
//! avião que já foi bom antes. O resultado guarda os k melhores de cada configuração (`Archive`), e não só o melhor
//! geral: assim o projetista compara a melhor de cada uma, e o refino com a malha cheia reavalia esses k no fim.
//!
//! Tudo em [0, 1], como nas outras buscas do núcleo. O gene da escolha vira um índice pela faixa: u em
//! [k/T, (k+1)/T) é a configuração k.
const std = @import("std");

pub const max_topologies = 8;
pub const max_genes = 64;
pub const max_kept = 8;

/// onde fica o trecho de cada configuração no vetor (o gene 0 é a escolha)
pub const Layout = struct {
    count: usize = 0,
    start: [max_topologies]usize = @splat(0),
    length: [max_topologies]usize = @splat(0),

    /// os trechos em sequência depois do gene da escolha, com `lengths[k]` variáveis na configuração k
    pub fn init(lengths: []const usize) error{TooMany}!Layout {
        if (lengths.len == 0 or lengths.len > max_topologies) return error.TooMany;
        var layout: Layout = .{ .count = lengths.len };
        var next: usize = 1;
        for (lengths, 0..) |length, k| {
            layout.start[k] = next;
            layout.length[k] = length;
            next += length;
        }
        if (next > max_genes) return error.TooMany;
        return layout;
    }

    /// o tamanho do vetor inteiro (a escolha mais todos os trechos)
    pub fn genes(layout: Layout) usize {
        return layout.start[layout.count - 1] + layout.length[layout.count - 1];
    }

    /// a configuração que o gene da escolha `vector[0]` aponta
    pub fn chosen(layout: Layout, vector: []const f64) usize {
        const scaled = std.math.clamp(vector[0], 0, 1) * @as(f64, @floatFromInt(layout.count));
        return @min(@as(usize, @intFromFloat(@floor(scaled))), layout.count - 1);
    }

    /// as variáveis que valem: o trecho da configuração escolhida
    pub fn active(layout: Layout, vector: []const f64) []const f64 {
        const k = layout.chosen(vector);
        return vector[layout.start[k]..][0..layout.length[k]];
    }
};

/// os k melhores de cada configuração (maior nota é melhor; NaN não entra), com o vetor inteiro de cada um
pub const Archive = struct {
    kept: usize,
    genes: usize,
    count: [max_topologies]usize = @splat(0),
    fitness: [max_topologies][max_kept]f64 = undefined,
    vectors: [max_topologies][max_kept][max_genes]f64 = undefined,

    /// um arquivo que guarda até `kept` de cada configuração, com vetores de `genes` números
    pub fn init(kept: usize, genes: usize) Archive {
        return .{ .kept = @min(@max(kept, 1), max_kept), .genes = @min(genes, max_genes) };
    }

    /// oferece um avião avaliado; entra se está entre os k melhores da configuração dele
    pub fn offer(archive: *Archive, topology: usize, fitness: f64, vector: []const f64) void {
        if (std.math.isNan(fitness) or topology >= max_topologies) return;
        const list = &archive.fitness[topology];
        var count = archive.count[topology];
        // repetido (o mesmo vetor) não ocupa duas vagas
        for (0..count) |i| if (std.mem.eql(f64, archive.vectors[topology][i][0..archive.genes], vector[0..archive.genes])) return;
        if (count == archive.kept and fitness <= list[count - 1]) return;
        if (count < archive.kept) count += 1;
        var slot = count - 1;
        while (slot > 0 and list[slot - 1] < fitness) : (slot -= 1) {
            list[slot] = list[slot - 1];
            archive.vectors[topology][slot] = archive.vectors[topology][slot - 1];
        }
        list[slot] = fitness;
        @memcpy(archive.vectors[topology][slot][0..archive.genes], vector[0..archive.genes]);
        archive.count[topology] = count;
    }

    /// os melhores guardados da configuração `topology`, da melhor para a pior
    pub fn best(archive: *const Archive, topology: usize) []const f64 {
        return archive.fitness[topology][0..archive.count[topology]];
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;
const de = @import("de.zig");

/// duas configurações: a 0 tem 2 variáveis e ótimo 1,0 em (0,2; 0,8); a 1 tem 3 e ótimo 1,5 em (0,5; 0,5; 0,5)
fn twoTopologies(layout: Layout, vector: []const f64) f64 {
    const values = layout.active(vector);
    var sum_sq: f64 = 0;
    switch (layout.chosen(vector)) {
        0 => {
            const target = [_]f64{ 0.2, 0.8 };
            for (values, target) |value, wanted| sum_sq += (value - wanted) * (value - wanted);
            return 1.0 - sum_sq;
        },
        else => {
            for (values) |value| sum_sq += (value - 0.5) * (value - 0.5);
            return 1.5 - sum_sq;
        },
    }
}

test "árvore de topologias: o trecho certo vale e o arquivo guarda a melhor de cada configuração" {
    const layout = try Layout.init(&.{ 2, 3 });
    try testing.expectEqual(@as(usize, 6), layout.genes());
    const sample = [_]f64{ 0.7, 9, 9, 0.1, 0.2, 0.3 };
    try testing.expectEqual(@as(usize, 1), layout.chosen(&sample));
    try testing.expectEqualSlices(f64, &.{ 0.1, 0.2, 0.3 }, layout.active(&sample));
    try testing.expectEqual(@as(usize, 1), layout.chosen(&.{ 1.0, 0, 0, 0, 0, 0 })); // u = 1 é a última
    // a DE do núcleo no vetor inteiro, com a semente fixa
    const dims = layout.genes();
    const pop_size = 24;
    var pop: [pop_size * max_genes]f64 = undefined;
    var trial: [pop_size * max_genes]f64 = undefined;
    var fit: [pop_size]f64 = undefined;
    var trial_fit: [pop_size]f64 = undefined;
    var archive = Archive.init(3, dims);
    _ = de.initPop(dims, pop_size, &.{ 0.1, 0.5, 0.5, 0.5, 0.5, 0.5 }, 11, &pop);
    for (0..pop_size) |i| {
        const vector = pop[i * dims ..][0..dims];
        fit[i] = twoTopologies(layout, vector);
        archive.offer(layout.chosen(vector), fit[i], vector);
    }
    for (0..150) |generation| {
        _ = de.trials(dims, pop_size, &pop, 0.5, 0.9, 11, generation, &trial);
        for (0..pop_size) |i| {
            const vector = trial[i * dims ..][0..dims];
            trial_fit[i] = twoTopologies(layout, vector);
            archive.offer(layout.chosen(vector), trial_fit[i], vector);
        }
        _ = de.select(dims, pop_size, &pop, &fit, &trial, &trial_fit);
    }
    // a população vai para a configuração 1 (a melhor), e o arquivo segura a melhor que a 0 chegou a ter
    try testing.expect(archive.best(0).len == 3 and archive.best(0)[0] > 0.9);
    try testing.expect(archive.best(1)[0] > 1.5 - 1e-6);
    // da melhor para a pior
    for (1..archive.best(0).len) |i| try testing.expect(archive.best(0)[i] <= archive.best(0)[i - 1]);
}
