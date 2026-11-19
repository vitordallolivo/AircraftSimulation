//! Esquema das estruturas exportadas, gerado em comptime por reflexão.
//!
//! O Python lê este texto e monta as estruturas ctypes sozinho: uma única fonte de
//! verdade para o layout (nada de copiar structs à mão nos dois lados).
//!   struct <Nome> <tamanho> <alinhamento>
//!   field <nome> <tipo> <contagem> <offset> [<Nome do enum ou dos flags>]      tipo: f64 | i32 | <Nome de struct>
//!   end
//! Um `enum(i32)` e um `packed struct(u32)` (bits com nome) vão como `i32`, com o nome do tipo no fim da linha, e o
//! esquema lista os nomes e os números de cada um, para o Python escrever pelo nome:
//!   enum <Nome>
//!   value <nome> <número>
//!   end
//!   flags <Nome>
//!   bit <nome> <posição>
//!   end
const std = @import("std");
const types = @import("types.zig");
const state = @import("sim/state.zig");
const limits = @import("limits.zig");

pub const version: u32 = 1;

/// em ordem de dependência (as de dentro primeiro)
pub const exported = .{
    types.Refinement,  types.Surface,     types.PropUnit,    types.Gear,           types.Tank,      types.Segment,      types.Event,      types.Pad,
    types.Payload,     types.Environment, types.Takeoff,        types.Autopilot, types.Pilot,        types.Modifier,   types.AeroTable,
    types.LltCache,    types.GroundTable, types.Params,      types.Events,         types.LogRow,    types.AeroCoeffs,   types.PanelState, types.PropPoint, types.SweepSummary,
    types.MassProps,   types.TrimPoint,   types.PerfRow,        envelope.EnvCfg,  envelope.EnvRow,     linear.LinModel, linear.LinSloshModel, autotune.Result,
    simple_perf.SimpleCfg,  simple_perf.SimpleRow,  simple_perf.SimpleSummary, sizing_types.VarSpec,  sizing_types.AirfoilData, sizing_types.PropSet,   sizing_types.Constraint,
    sizing_types.LayoutData, sizing_types.SizingCfg,  sizing_types.SizingOut,     sizing_types.OptOpts,  sizing_types.Individual,  optim_types.Tier,      optim_types.Program,
    sizing_ground.GroundRun,  geometry.Part,      geometry.Scene,       geometry.Report,  genetic.GaCfg,      cmaes.CmaState,  motorprop.MotorProp,
    structure_section.Material, structure_section.SectionPart, structure_section.SectionProperties, structure_section.PartStress,
    structure_section.Wall, structure_buckling.Orthotropic, structure_gear.Node, structure_gear.Member, structure_gear.MemberResult,
    structure_gear.Drop, structure_gear.DropResult, load_vn.VnNorm, load_vn.VnAircraft, load_vn.LoadCase, load_vn.VnResult,
    load_aeroelastic.Station, load_aeroelastic.Aeroelastic, load_flutter.Element, load_flutter.ModePoint, load_flutter.FlutterResult,
};
const structure_buckling = @import("structures/buckling.zig");
const structure_gear = @import("structures/gear.zig");
const load_vn = @import("loads/vn.zig");
const load_aeroelastic = @import("loads/aeroelastic.zig");
const load_flutter = @import("loads/flutter.zig");
const structure_section = @import("structures/section.zig");
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

const Tag = struct { kind: []const u8, count: usize, named: ?type = null };

/// o tipo de um campo no esquema: primitivo, struct ou um enum/flags (que vai como `i32` e leva o nome)
fn typeTag(comptime Ty: type) Tag {
    return switch (@typeInfo(Ty)) {
        .float => .{ .kind = "f64", .count = 1 },
        .int => .{ .kind = "i32", .count = 1 },
        .@"enum" => |enum_info| if (enum_info.tag_type == i32)
            .{ .kind = "i32", .count = 1, .named = Ty }
        else
            @compileError("enum da ABI tem de ser enum(i32): " ++ @typeName(Ty)),
        .array => |array_info| blk: {
            const inner = typeTag(array_info.child);
            break :blk .{ .kind = inner.kind, .count = array_info.len * inner.count, .named = inner.named };
        },
        .@"struct" => |struct_info| if (struct_info.layout == .@"packed")
            (if (struct_info.backing_integer == u32) .{ .kind = "i32", .count = 1, .named = Ty } else @compileError("struct packed da ABI tem de ser de 32 bits: " ++ @typeName(Ty)))
        else
            .{ .kind = shortName(Ty), .count = 1 },
        else => @compileError("tipo não suportado no ABI: " ++ @typeName(Ty)),
    };
}

/// os enums e os flags que aparecem nos campos das structs exportadas, sem repetir
const named_types: []const type = blk: {
    @setEvalBranchQuota(1_000_000);
    var found: []const type = &.{};
    for (exported) |Ty| {
        for (@typeInfo(Ty).@"struct".fields) |field| {
            const named = typeTag(field.type).named orelse continue;
            if (std.mem.indexOfScalar(type, found, named) != null) continue;
            for (found) |other| if (std.mem.eql(u8, shortName(other), shortName(named)))
                @compileError("dois enums da ABI com o mesmo nome: " ++ @typeName(other) ++ " e " ++ @typeName(named));
            found = found ++ .{named};
        }
    }
    break :blk found;
};

/// a lista de nomes e números de um enum, ou de bits de um flags
fn describeNamed(comptime Ty: type) []const u8 {
    comptime {
        var text: []const u8 = "";
        switch (@typeInfo(Ty)) {
            .@"enum" => |enum_info| {
                text = "enum " ++ shortName(Ty) ++ "\n";
                for (enum_info.fields) |value| text = text ++ std.fmt.comptimePrint("value {s} {d}\n", .{ value.name, value.value });
            },
            else => {
                text = "flags " ++ shortName(Ty) ++ "\n";
                for (@typeInfo(Ty).@"struct".fields) |bit| {
                    if (bit.name[0] == '_') continue;
                    if (bit.type != bool) @compileError("flags da ABI só com bool: " ++ @typeName(Ty));
                    text = text ++ std.fmt.comptimePrint("bit {s} {d}\n", .{ bit.name, @bitOffsetOf(Ty, bit.name) });
                }
            },
        }
        return text ++ "end\n";
    }
}

fn describe(comptime Ty: type) []const u8 {
    comptime {
        var text: []const u8 = std.fmt.comptimePrint("struct {s} {d} {d}\n", .{ shortName(Ty), @sizeOf(Ty), @alignOf(Ty) });
        for (@typeInfo(Ty).@"struct".fields) |field| {
            const tag = typeTag(field.type);
            text = text ++ std.fmt.comptimePrint("field {s} {s} {d} {d}", .{ field.name, tag.kind, tag.count, @offsetOf(Ty, field.name) });
            text = text ++ (if (tag.named) |named| " " ++ shortName(named) else "") ++ "\n";
        }
        return text ++ "end\n";
    }
}

pub const schema: [:0]const u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var text: []const u8 = std.fmt.comptimePrint(
        "abi {d}\nlimit surfaces {d}\nlimit props {d}\nlimit prop_pts {d}\nlimit gear {d}\nlimit tanks {d}\nlimit segments {d}\nlimit events {d}\nlimit instances {d}\nlimit mods {d}\nlimit nx {d}\nsnapshot {d}\n",
        .{ version, limits.max_surfaces, limits.max_props, limits.max_prop_pts, limits.max_gear, limits.max_tanks, limits.max_segments, limits.max_events, limits.max_instances, limits.max_mods, state.nx, @sizeOf(state.Run) },
    );
    text = text ++ std.fmt.comptimePrint("limit poly_coef {d}\npoly_terms", .{types.ThrustPoly.n_coef});
    for (0..types.ThrustPoly.n_coef) |k| text = text ++ " " ++ types.ThrustPoly.name(k);
    text = text ++ "\n";
    for (exported) |Ty| text = text ++ describe(Ty);
    for (named_types) |Ty| text = text ++ describeNamed(Ty);
    const terminated = text ++ "\x00";
    break :blk terminated[0..text.len :0];
};

/// FNV-1a de 64 bits do esquema (comptime): o Python recalcula sobre o texto que recebeu e confere
pub const schema_hash: u64 = blk: {
    @setEvalBranchQuota(10_000_000);
    var hash: u64 = 0xcbf29ce484222325;
    for (schema) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    break :blk hash;
};

test "esquema lista os enums e os flags pelo nome" {
    try std.testing.expect(std.mem.indexOf(u8, schema, "field aero_model i32 1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "enum AeroModel\nvalue strips 0\nvalue lifting_line 1\nvalue table 2\nend\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "flags Flags\nbit enabled 0\nbit axial 1\nbit swirl 2\nend\n") != null);
}

test "esquema tem todas as structs" {
    inline for (exported) |Ty| {
        try std.testing.expect(std.mem.indexOf(u8, schema, "struct " ++ comptime shortName(Ty) ++ " ") != null);
    }
}
