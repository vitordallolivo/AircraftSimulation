//! Onde estão os programas e os dados, vistos da tela inicial. No pacote instalado (o .exe do Windows, o
//! AppImage do Linux) tudo fica numa pasta só: a tela inicial, `aerosim`, `aeroopt`, `aerodrive` e `data/`. No
//! repositório, cada programa está em `<pasta>/zig-out/bin` e os dados na raiz. Esta parte só procura caminhos;
//! não abre janela, então tem teste.
const std = @import("std");
const builtin = @import("builtin");

pub const Program = enum { aerosim, aeroopt, aerodrive };

/// a terminação dos executáveis no sistema para o qual se compila
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// a pasta dos dados (a que tem `data/aircraft`): a do executável ou uma acima dela (até 4 níveis); null se não há
pub fn dataRoot(gpa: std.mem.Allocator, io: std.Io, exe_dir: []const u8) ?[]const u8 {
    var folder: []const u8 = exe_dir;
    for (0..5) |_| {
        const probe = std.fs.path.join(gpa, &.{ folder, "data", "aircraft" }) catch return null;
        defer gpa.free(probe);
        if (std.Io.Dir.cwd().access(io, probe, .{})) |_| return gpa.dupe(u8, folder) catch null else |_| {}
        folder = std.fs.path.dirname(folder) orelse return null;
    }
    return null;
}

/// os lugares onde o programa pode estar, na ordem de procura: ao lado da tela inicial (o pacote) e na pasta dele
/// no repositório (`<raiz>/<programa>/zig-out/bin`)
pub fn candidates(gpa: std.mem.Allocator, exe_dir: []const u8, root: ?[]const u8, program: Program) ![2]?[]const u8 {
    const name = try std.mem.concat(gpa, u8, &.{ @tagName(program), exe_suffix });
    defer gpa.free(name);
    const beside = try std.fs.path.join(gpa, &.{ exe_dir, name });
    const in_repo = if (root) |folder| try std.fs.path.join(gpa, &.{ folder, @tagName(program), "zig-out", "bin", name }) else null;
    return .{ beside, in_repo };
}

/// o primeiro lugar em que o programa existe
pub fn find(gpa: std.mem.Allocator, io: std.Io, exe_dir: []const u8, root: ?[]const u8, program: Program) ?[]const u8 {
    const places = candidates(gpa, exe_dir, root, program) catch return null;
    var found: ?[]const u8 = null;
    for (places) |place| {
        const path = place orelse continue;
        if (found == null) {
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                found = path;
                continue;
            } else |_| {}
        }
        gpa.free(path);
    }
    return found;
}

test "procura ao lado da tela inicial e depois na pasta do programa no repositório" {
    const gpa = std.testing.allocator;
    const places = try candidates(gpa, "/opt/as", "/home/x/repo", .aerosim);
    defer for (places) |place| if (place) |path| gpa.free(path);
    const sep = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("/opt/as" ++ sep ++ "aerosim" ++ exe_suffix, places[0].?);
    try std.testing.expectEqualStrings("/home/x/repo" ++ sep ++ "aerosim" ++ sep ++ "zig-out" ++ sep ++ "bin" ++ sep ++ "aerosim" ++ exe_suffix, places[1].?);
}

test "a raiz dos dados é a pasta do repositório (sobe de launcher/zig-out/bin)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const here_len = try std.process.currentPath(io, &buffer);
    const here = buffer[0..here_len];
    // os testes rodam em launcher/; a raiz (com data/aircraft) é a pasta de cima
    const start = try std.fs.path.join(gpa, &.{ here, "zig-out", "bin" });
    defer gpa.free(start);
    const root = dataRoot(gpa, io, start) orelse return error.SemDados;
    defer gpa.free(root);
    try std.testing.expectEqualStrings(std.fs.path.dirname(here).?, root);
}
