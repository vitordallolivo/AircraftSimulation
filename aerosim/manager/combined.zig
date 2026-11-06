//! Duas análises numa subaba só: os campos das duas num formulário, uma rodada depois da outra e um resultado com
//! o resumo, o diagnóstico e os gráficos das duas, sem os gráficos da segunda que repetem os da primeira. É o
//! "Voo nivelado e envelopes" com o desempenho da planilha (o antigo "Avião montado" da Desempenho), que repetia o
//! envelope, a potência e a subida.
const std = @import("std");
const simulation = @import("simulation");

const Json = std.json.Value;

/// o nome, o título e o texto da subaba, o grupo dos campos da segunda sem grupo e os gráficos da segunda que saem
pub const Info = struct {
    name: []const u8,
    title: [:0]const u8,
    area: []const u8,
    description: []const u8,
    second_group: []const u8,
    skip_second: []const []const u8 = &.{},
};

/// a análise que roda `First` e depois `Second` (as duas com a interface de `simulation.check`)
pub fn Combined(comptime First: type, comptime Second: type, comptime info: Info) type {
    return struct {
        pub const name = info.name;
        pub const title = info.title;
        pub const area = info.area;
        pub const description = info.description;
        pub const State = struct {
            first: First.State = .{},
            second: Second.State = .{},
            first_done: bool = false,
        };

        pub fn specs(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const memory = arena.allocator();
            const first = try written(memory, First.specs, .{ aircraft, values });
            const second = try written(memory, Second.specs, .{ aircraft, values });
            var merged = first;
            try appendAll(memory, &merged, second, "params", "", info.second_group);
            try appendAll(memory, &merged, second, "plots", "key", "");
            try merged.object.put(memory, "description", .{ .string = info.description });
            try write(out, merged);
        }

        pub fn start(run: *simulation.Run, state: *State, values: simulation.Values) simulation.Error!void {
            try First.start(run, &state.first, values);
            try Second.start(run, &state.second, values);
        }

        pub fn advance(run: *simulation.Run, state: *State) simulation.Error!bool {
            if (!state.first_done) {
                state.first_done = try First.advance(run, &state.first);
                if (state.first_done) run.progress = 0.5;
                return false;
            }
            return Second.advance(run, &state.second);
        }

        pub fn result(run: *simulation.Run, state: *State, out: *simulation.Writer) simulation.Error!void {
            const memory = run.memory();
            var first_text: std.Io.Writer.Allocating = .init(memory);
            try First.result(run, &state.first, &first_text.writer);
            var second_text: std.Io.Writer.Allocating = .init(memory);
            try Second.result(run, &state.second, &second_text.writer);
            var merged = try parsed(memory, first_text.written());
            const second = try parsed(memory, second_text.written());
            if (second.object.get("summary")) |summary| if (summary == .object) {
                const into = merged.object.getPtr("summary") orelse return error.Failed;
                if (into.* != .object) return error.Failed;
                var entries = summary.object.iterator();
                while (entries.next()) |entry| try into.object.put(memory, entry.key_ptr.*, entry.value_ptr.*);
            };
            try appendAll(memory, &merged, second, "checks", "", "");
            try appendAll(memory, &merged, second, "plots", "key", "");
            try write(out, merged);
        }

        /// junta a lista `field` da segunda na da primeira; as de `skip_second` (pela `skip_key`) ficam de fora e um
        /// campo sem grupo ganha `group`
        fn appendAll(memory: std.mem.Allocator, into: *Json, from: Json, field: []const u8, skip_key: []const u8, group: []const u8) !void {
            const source = from.object.get(field) orelse return;
            const target = into.object.getPtr(field) orelse return;
            if (source != .array or target.* != .array) return;
            for (source.array.items) |item| {
                if (skip_key.len > 0 and item == .object) if (item.object.get(skip_key)) |item_key| if (item_key == .string) {
                    const skipped = for (info.skip_second) |name_to_skip| {
                        if (std.mem.eql(u8, name_to_skip, item_key.string)) break true;
                    } else false;
                    if (skipped) continue;
                };
                var copy = item;
                if (group.len > 0 and copy == .object) {
                    const current = copy.object.get("group");
                    if (current == null or (current.? == .string and current.?.string.len == 0)) try copy.object.put(memory, "group", .{ .string = group });
                }
                try target.array.append(copy);
            }
        }
    };
}

/// os campos e os gráficos que `specs` escreve, lidos de volta como JSON
fn written(memory: std.mem.Allocator, comptime specs: anytype, args: anytype) simulation.Error!Json {
    var text: std.Io.Writer.Allocating = .init(memory);
    try @call(.auto, specs, .{&text.writer} ++ args);
    return parsed(memory, text.written());
}

fn parsed(memory: std.mem.Allocator, text: []const u8) simulation.Error!Json {
    const value = std.json.parseFromSliceLeaky(Json, memory, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
    if (value != .object) return error.Failed;
    return value;
}

fn write(out: *simulation.Writer, value: Json) !void {
    std.json.Stringify.value(value, .{}, out) catch return error.WriteFailed;
}
