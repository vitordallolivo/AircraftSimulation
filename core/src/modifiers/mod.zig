//! Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro sem mexer no resto
//! do núcleo. O Python monta os modificadores (dados); aqui ficam só os tipos conhecidos (código estático,
//! um `switch` por tipo). Ver README.md desta pasta.
//!
//! Onde entram (`physics/aero.zig`, em cada painel):
//!   v_painel = V_ar + ω × r + Σ v_induzida(r)        (só se houver modificador ligado: `p.n_mod > 0`)
//!   C_Di ← φ_solo(h) C_Di                            (método escolhido em `p.ground`)
const std = @import("std");
const L = @import("../limits.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const types = @import("types.zig");
pub const ground = @import("ground.zig");

/// o que os modificadores podem olhar no instante (preenchido por quem chama a aerodinâmica)
pub const Env = struct {
    n_prop: usize = 0,
    T: [L.max_props]f64 = [_]f64{0} ** L.max_props, // tração de cada motor (N)
    Q: [L.max_props]f64 = [_]f64{0} ** L.max_props, // torque (N·m)
    rps: [L.max_props]f64 = [_]f64{0} ** L.max_props, // rotação (1/s)

    pub const none: Env = .{};
};

/// o painel `i` está na máscara?
pub inline fn hits(mask: [2]i32, i: usize) bool {
    if (mask[0] == 0 and mask[1] == 0) return true;
    const w: u32 = @bitCast(mask[i / 32]);
    return (w >> @intCast(i % 32)) & 1 != 0;
}

/// velocidade induzida no painel `i` (centro em `r`, corpo) somando os modificadores ligados
pub fn induced(p: anytype, env: *const Env, i: usize, r: V3) V3 {
    _ = env;
    _ = r;
    var v = vec.zero;
    const n: usize = @intCast(p.n_mod);
    for (p.mods[0..n]) |*m| {
        if (m.enabled == 0 or !hits(m.surf_mask, i)) continue;
        v += switch (m.kind) {
            else => vec.zero, // tipo vazio ou desconhecido: nada
        };
    }
    return v;
}

const testing = std.testing;

test "máscara de painéis" {
    try testing.expect(hits(.{ 0, 0 }, 40)); // vazia = todos
    try testing.expect(hits(.{ 0b101, 0 }, 2));
    try testing.expect(!hits(.{ 0b101, 0 }, 1));
    try testing.expect(hits(.{ 0, 1 }, 32));
    try testing.expect(!hits(.{ 0, 1 }, 33));
}

test {
    _ = ground;
}
