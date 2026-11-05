//! O modelo aerodinâmico do voo, escolhido por `Params.aero_model` (`types.AeroModel`): quem a dinâmica, a trimagem e
//! a linearização chamam. `.strips` = faixas (`aero.computeEnv`, o de sempre: as contas são exatamente as de antes, e o
//! AeroDrive, que monta os `Params` com os padrões, fica igual); `.lifting_line` = linha sustentadora (`loads/llt.zig`,
//! `compute`; Phillips e Snyder, Goates e Hunsaker ou a não linear conforme `llt_method`); `.table` = tabela
//! (`aerotable.zig`) mais a fuselagem do núcleo se a tabela não a tem.
const types = @import("../types.zig");
const limits = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const aero = @import("aero.zig");
const table = @import("aerotable.zig");
const llt = @import("../loads/llt.zig");
const mods = @import("../modifiers/mod.zig");
const V3 = vec.V3;

pub const AeroModel = types.AeroModel;

/// forças e momentos aerodinâmicos pelo modelo de `params.aero_model` (faixas, linha sustentadora ou tabela)
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env) aero.Out {
    return switch (params.aero_model) {
        .lifting_line => llt.compute(params, Vr, body_rates, rcg, height, deflections, env),
        .table => blk: {
            var out = table.compute(params, Vr, body_rates, rcg, deflections);
            if (params.aero_tab.fus == 0 and vec.norm(Vr) > 0.1) {
                const fu = aero.fuselage(params, Vr, rcg);
                out.F += fu.F;
                out.M += fu.M;
                out.Fg[limits.groupIndex(.fuselage)] += fu.F;
                out.Mg[limits.groupIndex(.fuselage)] += fu.M;
            }
            break :blk out;
        },
        .strips, _ => aero.computeEnv(params, Vr, body_rates, rcg, height, deflections, env),
    };
}
