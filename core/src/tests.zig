//! Todos os testes do núcleo, por grupo. `zig build test` roda tudo; `-Dgrupo=math` roda só um grupo e
//! `-Dfiltro=<texto>` só os testes cujo nome contém o texto (os dois juntos também valem).
const std = @import("std");
const test_options = @import("test_options");

/// verdadeiro se o grupo `name` foi pedido em `-Dgrupo` (ou se nenhum foi pedido)
fn wanted(comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, test_options.test_group, "tudo") or std.mem.eql(u8, test_options.test_group, name);
}

// math: LUTs, polinômios e vetores
comptime {
    if (wanted("math")) {
        _ = @import("math/fmath_test.zig");
        _ = @import("math/vec.zig");
        _ = @import("math/poly.zig");
    }
}

// physics: atmosfera, aerodinâmica, propulsão, trem, massas, terreno, modificadores, colisão, linha sustentadora, varredura das asas
comptime {
    if (wanted("physics")) {
        _ = @import("physics/atmosphere.zig");
        _ = @import("physics/aero.zig");
        _ = @import("physics/propulsion.zig");
        _ = @import("physics/gear.zig");
        _ = @import("physics/mass.zig");
        _ = @import("physics/terrain.zig");
        _ = @import("modifiers/mod.zig");
        _ = @import("collision/collision.zig");
        _ = @import("loads/llt.zig");
        _ = @import("loads/sweep.zig");
    }
}

// control: guiamento e ajuste dos ganhos do piloto automático
comptime {
    if (wanted("control")) {
        _ = @import("control/guidance.zig");
        _ = @import("control/autotune.zig");
    }
}

// sim: decolagem, checkpoint, trimagem, envelope, desempenho simples, esquema da ABI e benchmarks
comptime {
    if (wanted("sim")) {
        _ = @import("sim/tests.zig");
        _ = @import("sim/envelope.zig");
        _ = @import("sim/simple_perf.zig");
        _ = @import("abi.zig");
        _ = @import("bench.zig");
    }
}

// sizing: estágios, tipos de aeronave, otimizadores, fuzzing das interfaces com tração mock
comptime {
    if (wanted("sizing")) {
        _ = @import("sizing/sizing.zig");
    }
}

// optim: programa da pontuação do aeroopt, gerações, CMA-ES, evolução diferencial, modelo local, substituto RBF,
// métodos da sensibilidade, hipercubo latino, busca guiada pela falha e álgebra linear
comptime {
    if (wanted("optim")) {
        _ = @import("optim/expr.zig");
        _ = @import("optim/ga.zig");
        _ = @import("optim/cmaes.zig");
        _ = @import("optim/de.zig");
        _ = @import("optim/localfit.zig");
        _ = @import("optim/rbf.zig");
        _ = @import("optim/sensmethods.zig");
        _ = @import("optim/sampling.zig");
        _ = @import("optim/guided.zig");
        _ = @import("math/linalg.zig");
    }
}

// geometry: hélice × peças, massas fora, pedaços soltos, chão
comptime {
    if (wanted("geometry")) {
        _ = @import("geometry/geometry.zig");
    }
}
