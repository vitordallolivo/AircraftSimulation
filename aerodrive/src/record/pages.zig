//! As páginas de gráficos de um voo gravado — as mesmas grandezas da aba Missão da GUI: planos
//! XY/XZ/ZY, altura, velocidades, ângulos, comandos, motor, bateria, coeficientes, trem, momentos,
//! vento. Só aparecem as páginas cujas colunas existem no arquivo. `ticks` dá as marcas dos eixos.
const std = @import("std");
const datalog = @import("datalog.zig");
const fz = @import("../util/fuzz.zig");

const deg = 180.0 / std.math.pi;

pub const Series = struct { col: []const u8, label: [:0]const u8, scale: f64 = 1 };

pub const Page = struct {
    title: [:0]const u8,
    x: []const u8 = "t",
    x_scale: f64 = 1,
    xlabel: [:0]const u8 = "t (s)",
    ylabel: [:0]const u8,
    ys: []const Series,
    equal_axes: bool = false, // planos: mesma escala nos dois eixos
};

pub const all = [_]Page{
    .{ .title = "Plano XY", .x = "n", .xlabel = "x (m) — eixo da pista", .ylabel = "y (m)", .ys = &.{.{ .col = "e", .label = "trajetória" }}, .equal_axes = true },
    .{ .title = "Plano XZ", .x = "n", .xlabel = "x (m)", .ylabel = "z (m)", .ys = &.{ .{ .col = "h", .label = "altura" }, .{ .col = "hgnd", .label = "terreno" } } },
    .{ .title = "Plano ZY", .x = "e", .xlabel = "y (m)", .ylabel = "z (m)", .ys = &.{.{ .col = "h", .label = "altura" }} },
    .{ .title = "Altura", .ylabel = "h (m)", .ys = &.{ .{ .col = "h", .label = "h" }, .{ .col = "href", .label = "h pedida" }, .{ .col = "hgnd", .label = "terreno" } } },
    .{ .title = "Velocidades", .ylabel = "V (m/s)", .ys = &.{ .{ .col = "Va", .label = "V ar" }, .{ .col = "Vg", .label = "V solo" }, .{ .col = "Vref", .label = "V pedida" } } },
    .{ .title = "Ângulos: θ, α, γ", .ylabel = "ângulo (°)", .ys = &.{ .{ .col = "theta", .label = "θ", .scale = deg }, .{ .col = "alpha", .label = "α", .scale = deg }, .{ .col = "gamma", .label = "γ", .scale = deg } } },
    .{ .title = "Rolagem e derrapagem", .ylabel = "ângulo (°)", .ys = &.{ .{ .col = "phi", .label = "φ", .scale = deg }, .{ .col = "beta", .label = "β", .scale = deg } } },
    .{ .title = "Proa e rumo", .ylabel = "ângulo (°)", .ys = &.{ .{ .col = "psi", .label = "ψ", .scale = deg }, .{ .col = "chi", .label = "χ", .scale = deg } } },
    .{ .title = "Velocidades angulares", .ylabel = "°/s", .ys = &.{ .{ .col = "p", .label = "p", .scale = deg }, .{ .col = "q", .label = "q", .scale = deg }, .{ .col = "r", .label = "r", .scale = deg } } },
    .{ .title = "Comandos", .ylabel = "δ (°)", .ys = &.{ .{ .col = "de", .label = "profundor", .scale = deg }, .{ .col = "da", .label = "aileron", .scale = deg }, .{ .col = "dr", .label = "leme", .scale = deg } } },
    .{ .title = "Acelerador", .ylabel = "%", .ys = &.{.{ .col = "thr", .label = "acelerador", .scale = 100 }} },
    .{ .title = "Rotação", .ylabel = "rpm", .ys = &.{.{ .col = "rpm0", .label = "motor 1" }} },
    .{ .title = "Tração", .ylabel = "N", .ys = &.{ .{ .col = "T", .label = "total" }, .{ .col = "thrust0", .label = "motor 1" } } },
    .{ .title = "Potência", .ylabel = "W", .ys = &.{.{ .col = "P", .label = "P" }} },
    .{ .title = "Bateria: corrente", .ylabel = "A", .ys = &.{.{ .col = "Ibat", .label = "I" }} },
    .{ .title = "Bateria: tensão", .ylabel = "V", .ys = &.{.{ .col = "Vbus", .label = "V" }} },
    .{ .title = "Energia gasta", .ylabel = "Wh", .ys = &.{.{ .col = "E", .label = "E" }} },
    .{ .title = "Fator de carga", .ylabel = "n", .ys = &.{.{ .col = "nz", .label = "n_z" }} },
    .{ .title = "Coeficientes: C_L", .ylabel = "C_L", .ys = &.{ .{ .col = "CL", .label = "total" }, .{ .col = "CL_wing", .label = "asa" }, .{ .col = "CL_ht", .label = "EH" } } },
    .{ .title = "Coeficientes: C_D", .ylabel = "C_D", .ys = &.{ .{ .col = "CD", .label = "total" }, .{ .col = "CDi", .label = "induzido" } } },
    .{ .title = "Reações no trem", .ylabel = "N", .ys = &.{ .{ .col = "N_steer", .label = "bequilha" }, .{ .col = "N_main", .label = "principal" }, .{ .col = "N_skid", .label = "bordo" } } },
    .{ .title = "Momento de rolamento L", .ylabel = "N·m", .ys = &.{ .{ .col = "L_tot", .label = "total" }, .{ .col = "L_wing", .label = "asa" }, .{ .col = "L_vt", .label = "EV" } } },
    .{ .title = "Momento de arfagem M", .ylabel = "N·m", .ys = &.{ .{ .col = "M_tot", .label = "total" }, .{ .col = "M_wing", .label = "asa" }, .{ .col = "M_ht", .label = "EH" } } },
    .{ .title = "Momento de guinada N", .ylabel = "N·m", .ys = &.{ .{ .col = "N_tot", .label = "total" }, .{ .col = "N_vt", .label = "EV" }, .{ .col = "N_prop", .label = "hélice" } } },
    .{ .title = "Vento", .ylabel = "m/s", .ys = &.{ .{ .col = "Wn", .label = "norte" }, .{ .col = "We", .label = "leste" }, .{ .col = "Wd", .label = "para baixo" } } },
    .{ .title = "Líquido (sloshing)", .ylabel = "N", .ys = &.{ .{ .col = "Fslx", .label = "F x" }, .{ .col = "Fsly", .label = "F y" } } },
    .{ .title = "Massa e CG", .ylabel = "kg / m", .ys = &.{ .{ .col = "m", .label = "massa" }, .{ .col = "xcg", .label = "x CG" } } },
};

/// a página tem o eixo x e ao menos uma curva no arquivo?
pub fn available(p: *const Page, t: *const datalog.Table) bool {
    if (t.col(p.x) == null) return false;
    for (p.ys) |s| if (t.col(s.col) != null) return true;
    return false;
}

/// índices das páginas disponíveis (no máximo `out.len`)
pub fn list(t: *const datalog.Table, out: []usize) []usize {
    var n: usize = 0;
    for (&all, 0..) |*p, i| if (n < out.len and available(p, t)) {
        out[n] = i;
        n += 1;
    };
    return out[0..n];
}

pub const Range = struct { lo: f64, hi: f64 };

/// faixa dos valores finitos (com escala); faixa vazia/plana vira algo desenhável
pub fn range(vals: []const f64, scale: f64) Range {
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (vals) |v| {
        const x = v * scale;
        if (!std.math.isFinite(x)) continue;
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    if (!(lo <= hi)) return .{ .lo = 0, .hi = 1 };
    if (hi - lo < 1e-9 * @max(1, @abs(hi))) {
        const pad = @max(0.5, 1e-3 * @abs(hi));
        return .{ .lo = lo - pad, .hi = hi + pad };
    }
    return .{ .lo = lo, .hi = hi };
}

pub const Ticks = struct { first: f64, step: f64, n: usize };

/// marcas "redondas" (1, 2, 5 × 10ⁿ) cobrindo [lo, hi], ~`want` marcas
pub fn ticks(lo: f64, hi: f64, want: usize) Ticks {
    if (!(std.math.isFinite(lo) and std.math.isFinite(hi) and hi > lo)) return .{ .first = 0, .step = 1, .n = 0 };
    const raw = (hi - lo) / @as(f64, @floatFromInt(@max(want, 2)));
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const r = raw / mag;
    const step = mag * (if (r < 1.5) @as(f64, 1) else if (r < 3.5) @as(f64, 2) else if (r < 7.5) @as(f64, 5) else @as(f64, 10));
    if (!(step > 0) or !std.math.isFinite(step)) return .{ .first = 0, .step = 1, .n = 0 };
    const first = @ceil(lo / step) * step;
    const n: usize = @intFromFloat(std.math.clamp(@floor((hi - first) / step + 1e-9) + 1, 0, 50));
    return .{ .first = first, .step = step, .n = n };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "todas as colunas das páginas existem no gravador" {
    for (all) |p| {
        var hit = false;
        for (datalog.columns) |c| if (std.mem.eql(u8, c, p.x)) {
            hit = true;
        };
        try testing.expect(hit);
        for (p.ys) |s| {
            var ok = false;
            for (datalog.columns) |c| if (std.mem.eql(u8, c, s.col)) {
                ok = true;
            };
            if (!ok) std.debug.print("coluna '{s}' não existe\n", .{s.col});
            try testing.expect(ok);
        }
    }
}

test "marcas redondas" {
    const k = ticks(0, 9.3, 5);
    try testing.expectEqual(@as(f64, 2), k.step);
    try testing.expectEqual(@as(usize, 5), k.n);
    const r = range(&.{ 3, 3, std.math.nan(f64) }, 1);
    try testing.expect(r.hi > r.lo);
}

fn fuzzTicks(_: void, src: *fz.Src) anyerror!void {
    const a = src.any();
    const b = src.any();
    const k = ticks(@min(a, b), @max(a, b), @as(usize, src.int(u8, 0, 20)));
    try testing.expect(k.n <= 50);
    var v: [16]f64 = undefined;
    for (&v) |*x| x.* = src.any();
    const r = range(v[0..@as(usize, src.int(u8, 0, 16))], src.any());
    try testing.expect(std.math.isFinite(r.lo) and std.math.isFinite(r.hi) and r.hi > r.lo);
}

test "fuzz: eixos dos gráficos" {
    try fz.check({}, fuzzTicks, .{});
}
