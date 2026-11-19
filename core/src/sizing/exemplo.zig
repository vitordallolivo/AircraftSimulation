//! O exemplo do README de `sizing/`: a envergadura e a área livres, uma pista de 50 m e dez iterações do enxame.
//! `cd core && python -m ziglang build exemplo -Dexemplo=sizing`
const std = @import("std");
const core = @import("aerosim");
const sizing = core.sizing.types;

var params: core.types.Params = .{};
var evaluated_buffer: [2048]sizing.Individual = undefined;

pub fn main() !void {
    core.test_aircraft(&params); // o motor e a hélice do avião dos testes viram o conjunto de tração
    var cfg: sizing.SizingCfg = .{};
    cfg.vars[sizing.variable(.span)] = .{ .lo = 1.5, .hi = 2.5 }; // o otimizador escolhe envergadura e área
    cfg.vars[sizing.variable(.area)] = .{ .lo = 0.6, .hi = 1.4 };
    cfg.vars[sizing.variable(.taper)] = .{ .lo = 0.7, .hi = 0.7 }; // o resto fica fixo (lo = hi)
    cfg.vars[sizing.variable(.motors)] = .{ .lo = 1, .hi = 1, .kind = .integer };
    cfg.sets[0] = .{ .unit = params.prop[0], .mass = 0.8, .P_max = 600 };
    cfg.n_cons = 1;
    cfg.cons[0] = .{ .q = .takeoff_run, .op = .at_most, .value = 50 }; // pista de 50 m

    const options: sizing.OptOpts = .{ .iterations = 10 };
    var evaluated: usize = 0;
    var best: sizing.SizingOut = .{};
    core.sizing.optimize(&cfg, &options, &params, &evaluated_buffer, &evaluated, &best, null, null);
    std.debug.print("{d} avaliações; viável: {}\n", .{ evaluated, best.feasible == 1 });
    std.debug.print("melhor: b = {d:.2} m  S = {d:.2} m²  MTOW = {d:.2} kg  corrida = {d:.1} m\n", .{
        best.x[sizing.variable(.span)], best.x[sizing.variable(.area)],
        best.q[sizing.quantity(.mtow)], best.q[sizing.quantity(.takeoff_run)],
    });
}
