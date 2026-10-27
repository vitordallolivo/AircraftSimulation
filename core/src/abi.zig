//! Esquema das estruturas exportadas, gerado em comptime por reflexão.
//!
//! O Python lê este texto e monta as estruturas ctypes sozinho: uma única fonte de
//! verdade para o layout (nada de copiar structs à mão nos dois lados).
//!   struct <Nome> <tamanho> <alinhamento>
//!   field <nome> <tipo> <contagem> <offset>      tipo: f64 | i32 | <Nome de struct>
//!   end
const std = @import("std");
const types = @import("types.zig");
const state = @import("sim/state.zig");
const limits = @import("limits.zig");

pub const version: u32 = 1;

/// em ordem de dependência (as de dentro primeiro)
pub const exported = .{
    types.Surface,     types.PropUnit,    types.Gear,           types.Tank,      types.Segment,      types.Event,      types.Pad,
    types.Payload,     types.Environment, types.Takeoff,        types.Autopilot, types.Pilot,        types.Modifier,   types.AeroTable,
    types.LltCache,    types.Params,      types.Events,         types.LogRow,    types.AeroCoeffs,   types.PanelState, types.PropPoint,
    types.MassProps,   types.TrimPoint,   types.PerfRow,        envelope.EnvCfg,  envelope.EnvRow,     linear.LinModel, autotune.Result,
    simple_perf.SimpleCfg,  simple_perf.SimpleRow,  simple_perf.SimpleSummary, sizing_types.VarSpec,  sizing_types.AirfoilData, sizing_types.PropSet,   sizing_types.Constraint,
    sizing_types.LayoutData, sizing_types.SizingCfg,  sizing_types.SizingOut,     sizing_types.OptOpts,  sizing_types.Individual,  optim_types.Tier,      optim_types.Program,
    sizing_ground.GroundRun,  geometry.Part,      geometry.Scene,       geometry.Report,  genetic.GaCfg,      cmaes.CmaState,  motorprop.MotorProp,
};
const sizing_types = @import("sizing/types.zig");
const optim_types = @import("optim/types.zig");
const sizing_ground = @import("sizing/ground.zig");
const motorprop = @import("sizing/motorprop.zig");
const geometry = @import("geometry/geometry.zig");
const genetic = @import("optim/ga.zig");
const cmaes = @import("optim/cmaes.zig");
const envelope = @import("sim/envelope.zig");
const linear = @import("sim/linear.zig");
const autotune = @import("control/autotune.zig");
const simple_perf = @import("sim/simple_perf.zig");

fn shortName(comptime Ty: type) []const u8 {
    const full = @typeName(Ty);
    const i = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[i + 1 ..];
}

fn typeTag(comptime Ty: type) struct { []const u8, usize } {
    return switch (@typeInfo(Ty)) {
        .float => .{ "f64", 1 },
        .int => .{ "i32", 1 },
        .array => |a| .{ typeTag(a.child)[0], a.len * typeTag(a.child)[1] },
        .@"struct" => .{ shortName(Ty), 1 },
        else => @compileError("tipo não suportado no ABI: " ++ @typeName(Ty)),
    };
}

fn describe(comptime Ty: type) []const u8 {
    comptime {
        var s: []const u8 = std.fmt.comptimePrint("struct {s} {d} {d}\n", .{ shortName(Ty), @sizeOf(Ty), @alignOf(Ty) });
        for (@typeInfo(Ty).@"struct".fields) |f| {
            const tag = typeTag(f.type);
            s = s ++ std.fmt.comptimePrint("field {s} {s} {d} {d}\n", .{ f.name, tag[0], tag[1], @offsetOf(Ty, f.name) });
        }
        return s ++ "end\n";
    }
}

pub const schema: [:0]const u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var s: []const u8 = std.fmt.comptimePrint(
        "abi {d}\nlimit surfaces {d}\nlimit props {d}\nlimit prop_pts {d}\nlimit gear {d}\nlimit tanks {d}\nlimit segments {d}\nlimit events {d}\nlimit instances {d}\nlimit mods {d}\nlimit nx {d}\nsnapshot {d}\n",
        .{ version, limits.max_surfaces, limits.max_props, limits.max_prop_pts, limits.max_gear, limits.max_tanks, limits.max_segments, limits.max_events, limits.max_instances, limits.max_mods, state.nx, @sizeOf(state.Run) },
    );
    s = s ++ std.fmt.comptimePrint("limit poly_coef {d}\npoly_terms", .{types.ThrustPoly.n_coef});
    for (0..types.ThrustPoly.n_coef) |k| s = s ++ " " ++ types.ThrustPoly.name(k);
    s = s ++ "\n";
    for (exported) |Ty| s = s ++ describe(Ty);
    const z = s ++ "\x00";
    break :blk z[0..s.len :0];
};

/// FNV-1a de 64 bits do esquema (comptime): o Python recalcula sobre o texto que recebeu e confere
pub const schema_hash: u64 = blk: {
    @setEvalBranchQuota(10_000_000);
    var h: u64 = 0xcbf29ce484222325;
    for (schema) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    break :blk h;
};

test "esquema tem todas as structs" {
    inline for (exported) |Ty| {
        try std.testing.expect(std.mem.indexOf(u8, schema, "struct " ++ comptime shortName(Ty) ++ " ") != null);
    }
}
