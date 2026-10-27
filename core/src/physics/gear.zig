//! Trem de pouso: N pontos de contato (triciclo, convencional, patins...).
//!
//! Cada contato é mola-amortecedor vertical, N = max(0, k d + c d'), com atrito de
//! rolamento na direção da roda e lateral, regularizados por tanh(v / 5 cm/s).
//! O contato direcionável vira com o comando dw. Freio nas principais.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("../sim/state.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;
const terrain = @import("terrain.zig");

/// força e momento do trem no corpo e a força normal de cada contato
pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    N: [limits.max_gear]f64 = [_]f64{0} ** limits.max_gear,
};

/// força e momento do trem (corpo, momento no CG `rcg`) com a roda direcionável virada `steer` (rad)
pub fn compute(ctx: state.Ctx, state_vector: []const f64, body_to_ned: vec.M3, rcg: V3, steer: f64) Out {
    var out = Out{};
    const params = ctx.p;
    const VB = V3{ state_vector[state.VEL_X], state_vector[state.VEL_Y], state_vector[state.VEL_Z] };
    const body_rates = V3{ state_vector[state.RATE_P], state_vector[state.RATE_Q], state_vector[state.RATE_R] };
    const n_gear: usize = @intCast(params.n_gear);
    for (params.gear[0..n_gear], 0..) |*gear_point, i| {
        const position = vec.v3(gear_point.r);
        const pc = vec.mul(body_to_ned, position);
        const pen = state_vector[state.DOWN] + pc[2] + terrain.height(params, state_vector[state.NORTH] + pc[0], state_vector[state.EAST] + pc[1]); // > 0: comprimido
        if (pen <= 0.0) continue;
        const vn = vec.mul(body_to_ned, VB + vec.cross(body_rates, position));
        const Nn = @max(0.0, gear_point.k * pen + gear_point.c * vn[2]);
        const dir = if (gear_point.kind == types.gear_steer) steer else 0.0;
        const sc = fmath.sincos(dir);
        const fn_ = vec.mul(body_to_ned, V3{ sc.c, sc.s, 0 });
        const fh = fmath.hypot(fn_[0], fn_[1]);
        const fx = fn_[0] / fh;
        const fy = fn_[1] / fh;
        const lx = -fy;
        const ly = fx;
        const vl = vn[0] * fx + vn[1] * fy;
        const vt = vn[0] * lx + vn[1] * ly;
        var mu = params.mu_roll;
        var mul = params.mu_lat;
        if (gear_point.kind == types.gear_main and ctx.f.brakes != 0) mu = params.mu_brake;
        if (gear_point.kind == types.gear_main and ctx.f.landed != 0) mu = params.mu_landing;
        if (gear_point.kind == types.gear_skid) {
            mu = params.mu_skid;
            mul = params.mu_skid;
        }
        const Fl = -mu * Nn * fmath.tanh(vl / 0.05);
        const Ft = -mul * Nn * fmath.tanh(vt / 0.05);
        const FB = vec.mulT(body_to_ned, V3{ Fl * fx + Ft * lx, Fl * fy + Ft * ly, -Nn });
        out.F += FB;
        out.M += vec.cross(position - rcg, FB);
        out.N[i] = Nn;
    }
    return out;
}

/// verdadeiro se algum ponto de contato toca o chão
pub fn touching(params: *const types.Params, state_vector: []const f64, body_to_ned: vec.M3) bool {
    const n_gear: usize = @intCast(params.n_gear);
    for (params.gear[0..n_gear]) |*gear_point| {
        const pc = vec.mul(body_to_ned, vec.v3(gear_point.r));
        if (state_vector[state.DOWN] + pc[2] + terrain.height(params, state_vector[state.NORTH] + pc[0], state_vector[state.EAST] + pc[1]) > 0.0) return true;
    }
    return false;
}

test "apoiado: força vertical equilibra" {
    var params = types.Params{};
    params.n_gear = 1;
    params.gear[0] = .{ .r = .{ 0, 0, 0.2 }, .k = 1000, .c = 0 };
    const flags = state.Flags{};
    const ctx = state.Ctx{ .p = &params, .f = &flags, .tR = -1, .h_ground = 0, .tg = -1 };
    var state_vector = [_]f64{0} ** state.nx;
    state_vector[state.DOWN] = -0.19; // 1 cm de compressão
    const out = compute(ctx, &state_vector, vec.rotation(0, 0, 0), vec.zero, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -10), out.F[2], 1e-6);
}
