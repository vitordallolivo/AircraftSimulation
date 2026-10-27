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

pub fn compute(p: *const types.Params, Vr: V3, w: V3, rcg: V3, h: f64, d: V3, env: *const mods.Env) aero.Out {
    return switch (p.aero_model) {
        linha => llt.compute(p, Vr, w, rcg, h, d, env),
        tabela => blk: {
            var o = table.compute(p, Vr, w, rcg, d);
            if (p.aero_tab.fus == 0 and vec.norm(Vr) > 0.1) {
                const fu = aero.fuselage(p, Vr, rcg);
                o.F += fu.F;
                o.M += fu.M;
                o.Fg[limits.group_fuselage] += fu.F;
                o.Mg[limits.group_fuselage] += fu.M;
            }
            break :blk o;
        },
        else => aero.computeEnv(p, Vr, w, rcg, h, d, env),
    };
}
