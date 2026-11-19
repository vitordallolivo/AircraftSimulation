//! O exemplo do README de `design/`: o projeto de exemplo da sprint, da asa ao avião montado, pelas etapas da tela.
//! `cd aerosim && python -m ziglang build exemplo -Dexemplo=design`
const std = @import("std");
const design = @import("design");

pub fn main(init: std.process.Init) !void {
    var project = try design.store.open(std.heap.page_allocator, init.io, "../data/sprint/projeto_s1223.json");
    project.folder = ".zig-cache/exemplo_sprint"; // o que mudar é gravado aqui, nunca em data/
    design.stages.use(project, init.io);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const wanted = [_]struct { stage: []const u8, keys: []const []const u8 }{
        .{ .stage = "asa", .keys = &.{ "b, S, AR", "C_L,max, α de estol (°)", "V de estol (massa estimada)" } },
        .{ .stage = "empenagem", .keys = &.{ "ponto neutro (% CMA)", "faixa do CG (% CMA)" } },
        .{ .stage = "motores", .keys = &.{ "PV (vazio), CP (carga paga), total (kg)", "corrida de decolagem (m)", "MTOW pela pista (kg); CP possível = MTOW − PV (kg)" } },
    };
    for (wanted) |item| {
        const request = try std.fmt.allocPrint(arena.allocator(), "\"name\": \"{s}\", \"do\": \"show\"", .{item.stage});
        const page = try design.stages.handle(arena.allocator(), init.io, request); // o mesmo pedido da tela
        const summary = page.object.get("summary").?.object;
        std.debug.print("{s}\n", .{item.stage});
        for (item.keys) |key| std.debug.print("  {s}: {s}\n", .{ key, summary.get(key).?.string });
    }
}
