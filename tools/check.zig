//! Os checks de regressão: confere que nada quebrou antes de mesclar na `main`.
//!
//!     zig build check                              fundação, AeroDrive e a regressão rápida
//!     zig build check -- --tudo                    a regressão inteira (com a Missão e as asas: alguns minutos)
//!     zig build check -- --grupos aerodrive,fundação
//!     zig build check -- --so mapa                 só os checks cujo nome contém o texto
//!     zig build check -- --ref <commit>            a referência da regressão (padrão: origin/main)
//!     zig build check -- --relatorio x.md          grava o resultado em Markdown
//!     zig build check -- --lista                   o que existe
//!
//! Grupos:
//!     fundação     testes do núcleo e do aerosim; mapa do código e tracking em dia; equações dos .md
//!     aerodrive    compila e testa o AeroDrive
//!     regressão    os aviões de `data/aircraft` pelas análises do aerosim, número a número contra a referência
//!
//! A regressão retrata os aviões (`tools/retrato.zig`) no código atual e numa cópia da referência (`git worktree`), e
//! compara. Os retratos ficam em `~/.cache/aerosim-checks`, um por commit; o do código atual só entra no cache sem
//! mudança local. Uma diferença não é sempre um erro (uma física nova pedida muda os números): o check diz o que mudou
//! e quem decide é quem lê. Sai com 1 se algum check falhar (os pulados não contam).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// o resultado de um check: `skipped` = não rodou (falta ferramenta, a referência não tem o retrato...)
const Outcome = struct {
    ok: bool,
    summary: []const u8,
    details: []const []const u8 = &.{},
    skipped: bool = false,
};

const Context = struct {
    memory: Allocator,
    io: std.Io,
    zig: []const u8,
    home: []const u8,
    reference: []const u8 = "origin/main",
    full: bool = false,
};

const Check = struct {
    group: []const u8,
    name: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
};

const checks = [_]Check{
    .{ .group = "fundação", .name = "núcleo: zig build test", .run = coreTests },
    .{ .group = "fundação", .name = "aerosim: zig build test", .run = aerosimTests },
    .{ .group = "fundação", .name = "mapa do código em dia (docs/MAP.md)", .run = codemapUpToDate },
    .{ .group = "fundação", .name = "tabelas do Quadro do TRACKING.md legíveis", .run = trackingUpToDate },
    .{ .group = "fundação", .name = "equações dos .md na forma que o GitHub desenha", .run = equationsGithubForm },
    .{ .group = "aerodrive", .name = "AeroDrive: compila (zig build)", .run = aerodriveBuild },
    .{ .group = "aerodrive", .name = "AeroDrive: zig build test", .run = aerodriveTests },
    .{ .group = "regressão", .name = "exemplos número a número contra a referência", .run = regression },
};

/// lê as opções, roda os checks escolhidos e imprime (e grava) o resultado
pub fn main(init: std.process.Init) !void {
    const memory = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(memory);
    var context: Context = .{
        .memory = memory,
        .io = io,
        .zig = init.environ_map.get("ZIG") orelse "zig",
        .home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".",
    };
    var groups: ?[]const u8 = null;
    var only: ?[]const u8 = null;
    var report: ?[]const u8 = null;
    var list = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else "";
        if (std.mem.eql(u8, arg, "--tudo")) context.full = true else if (std.mem.eql(u8, arg, "--lista")) list = true else if (std.mem.eql(u8, arg, "--grupos")) {
            groups = value;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--so")) {
            only = value;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--ref")) {
            context.reference = value;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--relatorio")) {
            report = value;
            index += 1;
        } else {
            std.debug.print("opção desconhecida: {s} (veja tools/check.zig)\n", .{arg});
            return error.UnknownOption;
        }
    }
    if (list) {
        for (checks) |check| std.debug.print("{s:<10} {s}\n", .{ check.group, check.name });
        return;
    }

    const Row = struct { check: Check, outcome: Outcome };
    var rows: std.ArrayList(Row) = .empty;
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    for (checks) |check| {
        if (groups) |chosen| if (!listed(chosen, check.group)) continue;
        if (only) |text| if (std.mem.indexOf(u8, check.name, text) == null) continue;
        std.debug.print("▶ {s} · {s} …\n", .{ check.group, check.name });
        const outcome = check.run(&context) catch |err| Outcome{ .ok = false, .summary = try std.fmt.allocPrint(memory, "o check quebrou: {s}", .{@errorName(err)}) };
        std.debug.print("  {s} {s}\n", .{ mark(outcome), outcome.summary });
        for (outcome.details) |line| std.debug.print("     {s}\n", .{line});
        try rows.append(memory, .{ .check = check, .outcome = outcome });
    }
    var failed: usize = 0;
    for (rows.items) |row| {
        if (!row.outcome.ok and !row.outcome.skipped) failed += 1;
    }
    const seconds = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - started, std.time.ns_per_s);
    std.debug.print("\n{d}/{d} ok em {d} s", .{ rows.items.len - failed, rows.items.len, seconds });
    if (failed > 0) std.debug.print("; falharam: {d}", .{failed});
    std.debug.print("\n", .{});

    if (report) |path| {
        var text: std.Io.Writer.Allocating = .init(memory);
        const writer = &text.writer;
        try writer.writeAll("| | grupo | check | resultado |\n|---|---|---|---|\n");
        for (rows.items) |row| try writer.print("| {s} | {s} | {s} | {s} |\n", .{ mark(row.outcome), row.check.group, row.check.name, row.outcome.summary });
        for (rows.items) |row| {
            if (row.outcome.details.len == 0) continue;
            try writer.print("\n**{s}**\n\n```\n", .{row.check.name});
            for (row.outcome.details) |line| try writer.print("{s}\n", .{line});
            try writer.writeAll("```\n");
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
    }
    if (failed > 0) std.process.exit(1);
}

fn listed(chosen: []const u8, group: []const u8) bool {
    var names = std.mem.tokenizeScalar(u8, chosen, ',');
    while (names.next()) |name| if (std.mem.eql(u8, name, group)) return true;
    return false;
}

fn mark(outcome: Outcome) []const u8 {
    return if (outcome.skipped) "⏭" else if (outcome.ok) "✅" else "❌";
}

// ------------------------------------------------------------------ comandos

const Command = struct { ok: bool, output: []const u8, seconds: i64 };

/// roda `argv` em `folder` e junta a saída e o erro
fn shell(context: *Context, folder: []const u8, argv: []const []const u8) !Command {
    const started = std.Io.Clock.awake.now(context.io).nanoseconds;
    const result = std.process.run(context.memory, context.io, .{ .argv = argv, .cwd = .{ .path = folder } }) catch |err| {
        return .{ .ok = false, .output = try std.fmt.allocPrint(context.memory, "não rodou {s}: {s}", .{ argv[0], @errorName(err) }), .seconds = 0 };
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const output = try std.mem.concat(context.memory, u8, &.{ result.stdout, result.stderr });
    return .{ .ok = ok, .output = output, .seconds = @intCast(@divTrunc(std.Io.Clock.awake.now(context.io).nanoseconds - started, std.time.ns_per_s)) };
}

/// as últimas `count` linhas de `text`
fn tail(memory: Allocator, text: []const u8, count: usize) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \r\n"), '\n');
    while (split.next()) |line| try lines.append(memory, line);
    return lines.items[lines.items.len -| count..];
}

/// `zig <args>` em `folder`, com a contagem de testes do Zig no resumo
fn zigRun(context: *Context, folder: []const u8, args: []const []const u8) !Outcome {
    const argv = try std.mem.concat(context.memory, []const u8, &.{ &.{context.zig}, args });
    const command = try shell(context, folder, argv);
    if (!command.ok) return .{ .ok = false, .summary = try std.fmt.allocPrint(context.memory, "falhou em {d} s", .{command.seconds}), .details = try tail(context.memory, command.output, 25) };
    var passed: []const u8 = "";
    var search = std.mem.splitScalar(u8, command.output, '\n');
    while (search.next()) |line| {
        if (std.mem.indexOf(u8, line, " tests passed")) |end| {
            var start = end;
            while (start > 0 and line[start - 1] != ' ') start -= 1;
            passed = try std.fmt.allocPrint(context.memory, "{s} testes, ", .{line[start..end]});
        }
    }
    return .{ .ok = true, .summary = try std.fmt.allocPrint(context.memory, "{s}em {d} s", .{ passed, command.seconds }) };
}

// ------------------------------------------------------------------ os checks

fn coreTests(context: *Context) !Outcome {
    return zigRun(context, "core", &.{ "build", "test", "--summary", "all" });
}

fn aerosimTests(context: *Context) !Outcome {
    return zigRun(context, "aerosim", &.{ "build", "test", "--summary", "all" });
}

fn aerodriveBuild(context: *Context) !Outcome {
    return zigRun(context, "aerodrive", &.{"build"});
}

fn aerodriveTests(context: *Context) !Outcome {
    return zigRun(context, "aerodrive", &.{ "build", "test", "--summary", "all" });
}

fn codemapUpToDate(context: *Context) !Outcome {
    const command = try shell(context, ".", &.{ context.zig, "build", "mapa", "--", "--check" });
    if (!command.ok) return .{ .ok = false, .summary = "desatualizado: rode zig build mapa", .details = try tail(context.memory, command.output, 3) };
    return .{ .ok = true, .summary = "em dia" };
}

fn trackingUpToDate(context: *Context) !Outcome {
    const command = try shell(context, ".", &.{ context.zig, "build", "tracking", "--", "--check" });
    if (!command.ok) return .{ .ok = false, .summary = "linha com colunas a mais ou a menos", .details = try tail(context.memory, command.output, 2) };
    return .{ .ok = true, .summary = "em dia" };
}

/// $$...$$ e $...$ passam antes pelo Markdown do GitHub, que come as barras invertidas e faz dos _ itálico: as
/// equações ficam em ```math (bloco) e $`...`$ (no texto)
fn equationsGithubForm(context: *Context) !Outcome {
    const memory = context.memory;
    const listed_files = try shell(context, ".", &.{ "git", "ls-files", "*.md" });
    var wrong: std.ArrayList([]const u8) = .empty;
    var paths = std.mem.tokenizeAny(u8, listed_files.output, "\r\n");
    while (paths.next()) |path| {
        if (std.mem.startsWith(u8, path, "data/")) continue;
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, memory, .limited(1 << 24)) catch continue;
        var fence: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (fence) |opened| {
                if (std.mem.startsWith(u8, line, opened)) fence = null;
                continue;
            }
            if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
                fence = line[0..3];
                continue;
            }
            if (badDollar(stripCode(memory, line) catch line)) try wrong.append(memory, try std.fmt.allocPrint(memory, "{s}: {s}", .{ path, line[0..@min(line.len, 80)] }));
        }
    }
    if (wrong.items.len > 0) return .{
        .ok = false,
        .summary = try std.fmt.allocPrint(memory, "{d} linhas com $$ ou $...$: use ```math ou $`...`$", .{wrong.items.len}),
        .details = wrong.items[0..@min(wrong.items.len, 5)],
    };
    return .{ .ok = true, .summary = "em dia" };
}

/// a linha sem as equações $`...`$ e sem o código entre crases
fn stripCode(memory: Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "$`")) {
            if (std.mem.indexOfPos(u8, line, i + 2, "`$")) |end| {
                i = end + 2;
                continue;
            }
        }
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| if (end > i + 1) {
                i = end + 1;
                continue;
            };
        }
        try out.append(memory, line[i]);
        i += 1;
    }
    return out.items;
}

/// `$$`, ou um `$x...$` que não seja `\$` nem `$$`
fn badDollar(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "$$") != null) return true;
    for (line, 0..) |char, i| {
        if (char != '$') continue;
        if (i > 0 and (line[i - 1] == '\\' or line[i - 1] == '$')) continue;
        if (i + 1 >= line.len or line[i + 1] == '$' or std.ascii.isWhitespace(line[i + 1])) continue;
        const close = std.mem.indexOfScalarPos(u8, line, i + 2, '$') orelse continue;
        if (close + 1 < line.len and line[close + 1] == '$') continue;
        return true;
    }
    return false;
}

test "equações: as formas que o GitHub desenha passam, as outras não" {
    const memory = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(memory);
    defer arena.deinit();
    try std.testing.expect(!badDollar(try stripCode(arena.allocator(), "a massa $`m`$ e o `$x$` do código")));
    try std.testing.expect(badDollar("a massa $m$ no texto"));
    try std.testing.expect(badDollar("bloco $$x$$"));
    try std.testing.expect(!badDollar("custa US$ 10 e R$ 20"));
}

// ------------------------------------------------------------------ regressão

/// o retrato dos aviões numa árvore: `avião\tanálise` → o JSON do resultado
const Portrait = std.StringArrayHashMapUnmanaged([]const u8);

fn regression(context: *Context) !Outcome {
    const memory = context.memory;
    const reference_sha = gitLine(context, &.{ "git", "rev-parse", context.reference }) catch
        return .{ .ok = false, .skipped = true, .summary = try std.fmt.allocPrint(memory, "git não achou a referência {s}", .{context.reference}) };
    const head_sha = try gitLine(context, &.{ "git", "rev-parse", "HEAD" });
    const status = try shell(context, ".", &.{ "git", "status", "--porcelain", "--untracked-files=no" });
    const dirty = std.mem.trim(u8, status.output, " \r\n").len > 0;
    const cache = try std.fs.path.join(memory, &.{ context.home, ".cache", "aerosim-checks" });
    try std.Io.Dir.cwd().createDirPath(context.io, cache);
    const tag = if (context.full) "completo" else "rapido";

    const tree = try std.fs.path.join(memory, &.{ cache, "trees", reference_sha[0..12] });
    std.Io.Dir.cwd().access(context.io, tree, .{}) catch {
        const added = try shell(context, ".", &.{ "git", "worktree", "add", "--detach", tree, reference_sha });
        if (!added.ok) return .{ .ok = false, .summary = "git worktree falhou", .details = try tail(memory, added.output, 5) };
    };
    const reference_file = try std.fmt.allocPrint(memory, "{s}/{s}_{s}.txt", .{ cache, reference_sha[0..12], tag });
    if (!try portrait(context, tree, reference_file)) return .{
        .ok = false,
        .skipped = true,
        .summary = try std.fmt.allocPrint(memory, "a referência {s} ainda não tem o retrato em Zig (zig build retrato)", .{context.reference}),
    };
    const current_file = if (dirty) try std.fmt.allocPrint(memory, "{s}/atual_{s}.txt", .{ cache, tag }) else try std.fmt.allocPrint(memory, "{s}/{s}_{s}.txt", .{ cache, head_sha[0..12], tag });
    if (dirty) std.Io.Dir.cwd().deleteFile(context.io, current_file) catch {};
    const here = try std.Io.Dir.cwd().realPathFileAlloc(context.io, ".", memory);
    if (!try portrait(context, here, current_file)) return .{ .ok = false, .summary = "o retrato do código atual falhou" };

    const reference = try readPortrait(context, reference_file);
    const current = try readPortrait(context, current_file);
    var details: std.ArrayList([]const u8) = .empty;
    var changed: usize = 0;
    for (reference.keys(), reference.values()) |key, before| {
        const after = current.get(key) orelse {
            try details.append(memory, try std.fmt.allocPrint(memory, "{s}: só na referência", .{key}));
            continue;
        };
        if (std.mem.eql(u8, before, after)) continue;
        changed += 1;
        var differences: std.ArrayList([]const u8) = .empty;
        const old = try std.json.parseFromSliceLeaky(std.json.Value, memory, before, .{});
        const new = try std.json.parseFromSliceLeaky(std.json.Value, memory, after, .{});
        try compare(memory, old, new, "", &differences);
        try details.append(memory, try std.fmt.allocPrint(memory, "{s}: {d} diferença(s)", .{ key, differences.items.len }));
        for (differences.items[0..@min(differences.items.len, 6)]) |line| try details.append(memory, try std.fmt.allocPrint(memory, "    {s}", .{line}));
        if (differences.items.len > 6) try details.append(memory, try std.fmt.allocPrint(memory, "    … +{d}", .{differences.items.len - 6}));
    }
    for (current.keys()) |key| if (reference.get(key) == null) try details.append(memory, try std.fmt.allocPrint(memory, "{s}: só no atual", .{key}));
    const where = try std.fmt.allocPrint(memory, "{s} ({s}) → {s}", .{ context.reference, reference_sha[0..8], if (dirty) "atual com mudanças locais" else head_sha[0..8] });
    if (changed > 0) return .{ .ok = false, .summary = try std.fmt.allocPrint(memory, "{d} de {d} resultados mudaram; {s}", .{ changed, reference.count(), where }), .details = details.items };
    return .{ .ok = true, .summary = try std.fmt.allocPrint(memory, "{d} resultados idênticos; {s}", .{ reference.count(), where }), .details = details.items };
}

fn gitLine(context: *Context, argv: []const []const u8) ![]const u8 {
    const command = try shell(context, ".", argv);
    if (!command.ok) return error.GitFailed;
    return std.mem.trim(u8, command.output, " \r\n");
}

/// grava o retrato da árvore `tree` em `file` (se ainda não existe); falso se a árvore não sabe retratar
fn portrait(context: *Context, tree: []const u8, file: []const u8) !bool {
    if (std.Io.Dir.cwd().access(context.io, file, .{})) |_| return true else |_| {}
    const folder = try std.fs.path.join(context.memory, &.{ tree, "aerosim" });
    const aircraft = try std.fs.path.join(context.memory, &.{ tree, "data", "aircraft" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.memory, &.{ context.zig, "build", "retrato", "--", aircraft, file });
    if (!context.full) try argv.append(context.memory, "--rapido");
    std.debug.print("  retratando {s}\n", .{tree});
    const command = try shell(context, folder, argv.items);
    if (!command.ok) std.debug.print("{s}\n", .{command.output[command.output.len -| 2000..]});
    return command.ok;
}

fn readPortrait(context: *Context, file: []const u8) !Portrait {
    const text = try std.Io.Dir.cwd().readFileAlloc(context.io, file, context.memory, .unlimited);
    var map: Portrait = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const first = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const second = std.mem.indexOfScalarPos(u8, line, first + 1, '\t') orelse continue;
        try map.put(context.memory, line[0..second], line[second + 1 ..]);
    }
    return map;
}

/// as diferenças entre dois resultados, com o caminho de cada uma
fn compare(memory: Allocator, old: std.json.Value, new: std.json.Value, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (old == .object and new == .object) {
        for (old.object.keys(), old.object.values()) |key, value| {
            const child_path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ path, key });
            if (new.object.get(key)) |other| try compare(memory, value, other, child_path, out) else try out.append(memory, try std.fmt.allocPrint(memory, "{s}: só na referência", .{child_path}));
        }
        for (new.object.keys()) |key| if (old.object.get(key) == null) try out.append(memory, try std.fmt.allocPrint(memory, "{s}/{s}: só no atual", .{ path, key }));
        return;
    }
    if (old == .array and new == .array) {
        if (old.array.items.len != new.array.items.len) return out.append(memory, try std.fmt.allocPrint(memory, "{s}: tamanho {d} → {d}", .{ path, old.array.items.len, new.array.items.len }));
        var largest: f64 = 0;
        var numeric = true;
        for (old.array.items, new.array.items, 0..) |a, b, i| {
            if (number(a) != null and number(b) != null) {
                const difference = @abs(number(a).? - number(b).?);
                if (difference > largest or std.math.isNan(difference)) largest = difference;
            } else {
                numeric = false;
                try compare(memory, a, b, try std.fmt.allocPrint(memory, "{s}[{d}]", .{ path, i }), out);
            }
        }
        if (numeric and largest != 0) try out.append(memory, try std.fmt.allocPrint(memory, "{s}: maior diferença {e:.3}", .{ path, largest }));
        return;
    }
    if (number(old) != null and number(new) != null) {
        if (number(old).? != number(new).?) try out.append(memory, try std.fmt.allocPrint(memory, "{s}: {d} → {d}", .{ path, number(old).?, number(new).? }));
        return;
    }
    const before = try std.json.Stringify.valueAlloc(memory, old, .{});
    const after = try std.json.Stringify.valueAlloc(memory, new, .{});
    if (!std.mem.eql(u8, before, after)) try out.append(memory, try std.fmt.allocPrint(memory, "{s}: {s} → {s}", .{ path, before[0..@min(before.len, 60)], after[0..@min(after.len, 60)] }));
}

fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}
