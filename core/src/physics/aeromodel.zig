//! O modelo aerodinâmico do voo, escolhido por `Params.aero_model`: quem a dinâmica, a trimagem e a linearização
//! chamam. 0 = faixas (`aero.computeEnv`, o de sempre: com 0 as contas são exatamente as de antes, e o AeroDrive,
//! que monta os `Params` com os padrões, fica igual); 1 = linha sustentadora (`loads/llt.zig`, `compute`; Phillips e
//! Snyder ou Goates e Hunsaker conforme `llt_joint` e `llt_blend`); 2 = tabela (`aerotable.zig`) mais a fuselagem do
//! núcleo se a tabela não a tem.
const types = @import("../types.zig");
const limits = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const aero = @import("aero.zig");
const table = @import("aerotable.zig");
const llt = @import("../loads/llt.zig");
const mods = @import("../modifiers/mod.zig");
const V3 = vec.V3;

pub const faixas = 0;
pub const linha = 1;
pub const tabela = 2;

/// forças e momentos aerodinâmicos pelo modelo de `params.aero_model` (faixas, linha sustentadora ou tabela)
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env) aero.Out {
    return switch (params.aero_model) {
        linha => llt.compute(params, Vr, body_rates, rcg, height, deflections, env),
        tabela => blk: {
            var out = table.compute(params, Vr, body_rates, rcg, deflections);
            if (params.aero_tab.fus == 0 and vec.norm(Vr) > 0.1) {
                const fu = aero.fuselage(params, Vr, rcg);
                out.F += fu.F;
                out.M += fu.M;
                out.Fg[limits.group_fuselage] += fu.F;
                out.Mg[limits.group_fuselage] += fu.M;
            }
            break :blk out;
        },
        else => aero.computeEnv(params, Vr, body_rates, rcg, height, deflections, env),
    };
}
