//! Esquema das estruturas exportadas, gerado em comptime por reflexão.
//!
//! O Python lê este texto e monta as estruturas ctypes sozinho: uma única fonte de
//! verdade para o layout (nada de copiar structs à mão nos dois lados).
//!   struct <Nome> <tamanho> <alinhamento>
//!   field <nome> <tipo> <contagem> <offset>      tipo: f64 | i32 | <Nome de struct>
//!   end
const std = @import("std");
const T = @import("types.zig");
const S = @import("sim/state.zig");
const L = @import("limits.zig");

pub const version: u32 = 1;

/// em ordem de dependência (as de dentro primeiro)
pub const exported = .{
    T.Surface,     T.PropUnit,    T.Gear,           T.Tank,      T.Segment,      T.Event,      T.Pad,
    T.Payload,     T.Environment, T.Takeoff,        T.Autopilot, T.Pilot,        T.Modifier,   T.AeroTable,
    T.LltCache,    T.Params,      T.Events,         T.LogRow,    T.AeroCoeffs,   T.PanelState, T.PropPoint,
    T.MassProps,   T.TrimPoint,   T.PerfRow,        env.EnvCfg,  env.EnvRow,     lin.LinModel, at.Result,
    sp.SimpleCfg,  sp.SimpleRow,  sp.SimpleSummary, sz.VarSpec,  sz.AirfoilData, sz.PropSet,   sz.Constraint,
    sz.LayoutData, sz.SizingCfg,  sz.SizingOut,     sz.OptOpts,  sz.Individual,  ot.Tier,      ot.Program,
    gr.GroundRun,  geo.Part,      geo.Scene,       geo.Report,  ga.GaCfg,
};
const sz = @import("sizing/types.zig");
const ot = @import("optim/types.zig");
const gr = @import("sizing/ground.zig");
const geo = @import("geometry/geometry.zig");
const ga = @import("optim/ga.zig");
const env = @import("sim/envelope.zig");
const lin = @import("sim/linear.zig");
const at = @import("control/autotune.zig");
const sp = @import("sim/simple_perf.zig");

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
        .{ version, L.max_surfaces, L.max_props, L.max_prop_pts, L.max_gear, L.max_tanks, L.max_segments, L.max_events, L.max_instances, L.max_mods, S.nx, @sizeOf(S.Run) },
    );
    s = s ++ std.fmt.comptimePrint("limit poly_coef {d}\npoly_terms", .{T.ThrustPoly.n_coef});
    for (0..T.ThrustPoly.n_coef) |k| s = s ++ " " ++ T.ThrustPoly.name(k);
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
