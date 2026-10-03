//! Leitura do arquivo do avião salvo pela GUI (`data/aircraft/*.json`, "meus aviões").
//!
//! O arquivo é `{"formato": ..., "aeronave": {...}}` (ou a aeronave direto). Só os campos que o
//! aerodrive usa são lidos; o resto é ignorado. Depois de ler, `validate` confere tudo o que pode
//! quebrar o desenho e devolve um erro com o nome do componente em `Diag` (nunca trava).
const std = @import("std");
const fz = @import("../util/fuzz.zig");

// ------------------------------------------------------------------ esquema (nomes iguais aos do JSON)
pub const Section = struct { y: f64 = 0, chord: f64 = 0.3, x_offset: f64 = 0, twist: f64 = 0 };

pub const Control = struct {
    kind: []const u8 = "aileron",
    span_start: f64 = 0.6,
    span_end: f64 = 1.0,
    chord_frac: f64 = 0.25,
    deflection: f64 = 0,
};

pub const Device = struct {
    kind: []const u8 = "winglet",
    eta: f64 = 1.0,
    dx: f64 = 0,
    height: f64 = 0.15,
    root_chord: f64 = 0,
    taper: f64 = 0.6,
    sweep: f64 = 30,
    cant: f64 = 10,
    toe: f64 = 0,
    profile: []const u8 = "NACA 0010",
    enabled: bool = true,
};

pub const Airfoil = struct { name: []const u8 = "NACA 0012", coords: []const [2]f64 = &.{} };

pub const Surface = struct {
    name: []const u8 = "asa",
    role: []const u8 = "wing",
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    sections: []const Section = &.{},
    dihedral: f64 = 0,
    incidence: f64 = 0,
    airfoil: Airfoil = .{},
    symmetric: bool = true,
    vertical: bool = false,
    controls: []const Control = &.{},
    devices: []const Device = &.{},
    enabled: bool = true,
};

pub const Fuselage = struct { enabled: bool = false, x_nose: f64 = 0.6, length: f64 = 1.2, width: f64 = 0.15, height: f64 = 0.15, z: f64 = 0 };
pub const Boom = struct {
    enabled: bool = false,
    x_start: f64 = -0.3,
    length: f64 = 0.8,
    diameter: f64 = 0.025,
    z: f64 = 0,
    attach_tail: bool = true,

    pub fn xEnd(b: Boom) f64 {
        return b.x_start - b.length;
    }
};
pub const Propeller = struct { D: f64 = 0.381 };
pub const Propulsion = struct {
    name: []const u8 = "motor",
    x: f64 = 0.55,
    y: f64 = 0,
    z: f64 = 0,
    tilt: f64 = 0,
    toe: f64 = 0,
    sense: f64 = 1,
    enabled: bool = true,
    propeller: Propeller = .{},
};
pub const GearLeg = struct { kind: []const u8 = "main", x: f64 = 0, y: f64 = 0, z: f64 = 0.2 };
pub const Gear = struct {
    layout: []const u8 = "tricycle",
    main_x: f64 = -0.05,
    main_track: f64 = 0.6,
    main_z: f64 = 0.22,
    steer_x: f64 = 0.45,
    steer_z: f64 = 0.22,
    tail_skid: bool = true,
    skid_x: f64 = -1.1,
    skid_z: f64 = 0,
    custom: []const GearLeg = &.{},
};
pub const Tank = struct {
    name: []const u8 = "tanque",
    x: f64 = 0.1,
    y: f64 = 0,
    z: f64 = 0.05,
    side: f64 = 0.14,
    volume: f64 = 2.0, // L
    height: f64 = 0.12,
    shape: []const u8 = "square",

    pub fn baseArea(t: Tank) f64 {
        return if (std.mem.eql(u8, t.shape, "square")) t.side * t.side else std.math.pi * t.side * t.side / 4.0;
    }
    /// altura do líquido (m), pelo volume — igual a `SloshTank.fill`
    pub fn fill(t: Tank) f64 {
        return t.volume / 1000.0 / t.baseArea();
    }
};
pub const Payload = struct { enabled: bool = false, mass: f64 = 2, x: f64 = 0, y: f64 = 0, z: f64 = 0.08 };
pub const Ballast = struct { enabled: bool = false, mass: f64 = 0.3, x: f64 = 0.4, y: f64 = 0, z: f64 = 0 };
pub const Airfield = struct {
    takeoff_from: []const u8 = "chão",
    table_height: f64 = 1.0,
    table_length: f64 = 15.0,
    table_back: f64 = 1.0,
    table_width: f64 = 2.0,
    landing_on: []const u8 = "chão",
    platform_height: f64 = 0.5,
    platform_length: f64 = 80.0,
    platform_width: f64 = 6.0,
    platform_start: f64 = 50.0,
    x_warning: f64 = 60.0,
    z_warning: f64 = 1.0,
};

pub const Aircraft = struct {
    name: []const u8 = "aeronave",
    surfaces: []const Surface = &.{},
    fuselage: Fuselage = .{},
    boom: Boom = .{},
    propulsion: []const Propulsion = &.{},
    gear: Gear = .{},
    tanks: []const Tank = &.{},
    payload: Payload = .{},
    ballast: Ballast = .{},
    airfield: Airfield = .{},
};

// ------------------------------------------------------------------ limites e erros
pub const limits = struct {
    pub const surfaces = 16;
    pub const sections = 32;
    pub const controls = 8;
    pub const devices = 8;
    pub const props = 8;
    pub const tanks = 8;
    pub const gear_legs = 16;
    pub const size = 50.0; // m: qualquer coordenada/medida acima disto é arquivo estragado
};

pub const Error = error{
    NotJson,
    NoAircraft,
    BadField,
    TooMany,
    NonFinite,
    TooLarge,
    NotPositive,
    TooFewSections,
    BadFraction,
};

/// o que deu errado, em português, para mostrar na tela
pub const Diag = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn set(d: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..];
        d.len = s.len;
    }
    pub fn text(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

/// a aeronave lida e a memória dela (libere com `deinit`)
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    ac: Aircraft,

    pub fn deinit(l: *Loaded) void {
        l.arena.deinit();
    }
};

/// lê o texto do arquivo e valida
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diag) (Error || std.mem.Allocator.Error)!Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        diag.set("o arquivo não é JSON válido ({s})", .{@errorName(e)});
        return error.NotJson;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            diag.set("o arquivo não tem uma aeronave", .{});
            return error.NoAircraft;
        },
    };
    const node = obj.get("aeronave") orelse root;
    if (node != .object or node.object.get("surfaces") == null) {
        diag.set("o arquivo não tem uma aeronave (falta 'surfaces')", .{});
        return error.NoAircraft;
    }
    const ac = std.json.parseFromValueLeaky(Aircraft, a, node, .{ .ignore_unknown_fields = true }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        diag.set("campo com tipo errado na aeronave ({s})", .{@errorName(e)});
        return error.BadField;
    };
    try validate(&ac, diag);
    return .{ .arena = arena, .ac = ac };
}

fn num(diag: *Diag, what: []const u8, field: []const u8, v: f64) Error!void {
    if (!std.math.isFinite(v)) {
        diag.set("{s}: '{s}' não é um número finito", .{ what, field });
        return error.NonFinite;
    }
    if (@abs(v) > limits.size) {
        diag.set("{s}: '{s}' = {d} fora de ±{d} m", .{ what, field, v, limits.size });
        return error.TooLarge;
    }
}

fn pos(diag: *Diag, what: []const u8, field: []const u8, v: f64) Error!void {
    try num(diag, what, field, v);
    if (!(v > 0)) {
        diag.set("{s}: '{s}' tem de ser > 0 (está {d})", .{ what, field, v });
        return error.NotPositive;
    }
}

fn count(diag: *Diag, what: []const u8, n: usize, max: usize) Error!void {
    if (n > max) {
        diag.set("{s}: {d} itens (máximo {d})", .{ what, n, max });
        return error.TooMany;
    }
}

/// tudo o que o desenho precisa estar certo; mensagens com o nome do componente
pub fn validate(ac: *const Aircraft, diag: *Diag) Error!void {
    try count(diag, "superfícies", ac.surfaces.len, limits.surfaces);
    for (ac.surfaces) |s| {
        if (!s.enabled) continue;
        try count(diag, s.name, s.sections.len, limits.sections);
        try count(diag, s.name, s.controls.len, limits.controls);
        try count(diag, s.name, s.devices.len, limits.devices);
        if (s.sections.len < 2) {
            diag.set("{s}: precisa de pelo menos 2 seções (raiz e ponta)", .{s.name});
            return error.TooFewSections;
        }
        inline for (.{ "x", "y", "z", "dihedral", "incidence" }) |f| try num(diag, s.name, f, @field(s, f));
        for (s.sections) |q| {
            try num(diag, s.name, "y", q.y);
            try num(diag, s.name, "x_offset", q.x_offset);
            try num(diag, s.name, "twist", q.twist);
            try pos(diag, s.name, "chord", q.chord);
        }
        if (!(semispan(&s) > 0)) {
            diag.set("{s}: envergadura nula", .{s.name});
            return error.NotPositive;
        }
        if (@abs(s.dihedral) > 90 or @abs(s.incidence) > 45) {
            diag.set("{s}: diedro/incidência fora do razoável", .{s.name});
            return error.TooLarge;
        }
        for (s.controls) |c| {
            inline for (.{ "span_start", "span_end", "chord_frac", "deflection" }) |f| {
                if (!std.math.isFinite(@field(c, f))) {
                    diag.set("{s}/{s}: '{s}' não é finito", .{ s.name, c.kind, f });
                    return error.NonFinite;
                }
            }
            if (c.chord_frac <= 0 or c.chord_frac >= 1 or c.span_start > c.span_end or @abs(c.deflection) > 90) {
                diag.set("{s}/{s}: frações do comando fora de 0..1", .{ s.name, c.kind });
                return error.BadFraction;
            }
        }
        for (s.devices) |d| {
            if (!d.enabled) continue;
            inline for (.{ "eta", "dx", "root_chord", "taper", "sweep", "cant", "toe" }) |f| try num(diag, d.kind, f, @field(d, f));
            try num(diag, d.kind, "height", d.height);
            if (d.taper < 0 or @abs(d.sweep) > 80) {
                diag.set("{s}: afilamento/enflechamento fora do razoável", .{d.kind});
                return error.BadFraction;
            }
        }
    }
    if (ac.fuselage.enabled) {
        const f = ac.fuselage;
        inline for (.{ "x_nose", "z" }) |n| try num(diag, "fuselagem", n, @field(f, n));
        inline for (.{ "length", "width", "height" }) |n| try pos(diag, "fuselagem", n, @field(f, n));
    }
    if (ac.boom.enabled) {
        const b = ac.boom;
        inline for (.{ "x_start", "z" }) |n| try num(diag, "tubo", n, @field(b, n));
        inline for (.{ "length", "diameter" }) |n| try pos(diag, "tubo", n, @field(b, n));
    }
    try count(diag, "motores", ac.propulsion.len, limits.props);
    for (ac.propulsion) |u| {
        if (!u.enabled) continue;
        inline for (.{ "x", "y", "z", "tilt", "toe" }) |n| try num(diag, u.name, n, @field(u, n));
        try pos(diag, u.name, "propeller.D", u.propeller.D);
    }
    try count(diag, "tanques", ac.tanks.len, limits.tanks);
    for (ac.tanks) |t| {
        inline for (.{ "x", "y", "z" }) |n| try num(diag, t.name, n, @field(t, n));
        inline for (.{ "side", "height" }) |n| try pos(diag, t.name, n, @field(t, n));
        if (!std.math.isFinite(t.volume) or t.volume < 0 or t.fill() > limits.size) {
            diag.set("{s}: volume de líquido inválido", .{t.name});
            return error.BadFraction;
        }
    }
    try count(diag, "trem (custom)", ac.gear.custom.len, limits.gear_legs);
    const g = ac.gear;
    inline for (.{ "main_x", "main_track", "main_z", "steer_x", "steer_z", "skid_x", "skid_z" }) |n| try num(diag, "trem", n, @field(g, n));
    for (g.custom) |q| inline for (.{ "x", "y", "z" }) |n| try num(diag, "trem (custom)", n, @field(q, n));
    if (ac.payload.enabled) inline for (.{ "x", "y", "z" }) |n| try num(diag, "LAPES", n, @field(ac.payload, n));
    if (ac.ballast.enabled) {
        inline for (.{ "x", "y", "z" }) |n| try num(diag, "lastro", n, @field(ac.ballast, n));
        if (!std.math.isFinite(ac.ballast.mass) or ac.ballast.mass < 0 or ac.ballast.mass > 1000) {
            diag.set("lastro: massa inválida", .{});
            return error.BadFraction;
        }
    }
}

// ------------------------------------------------------------------ geometria derivada (igual à GUI)
pub fn semispan(s: *const Surface) f64 {
    var m: f64 = 0;
    for (s.sections) |q| m = @max(m, q.y);
    return m;
}

/// seções em ordem de y (a GUI não obriga a ordem); `buf` guarda a cópia
pub fn sortedSections(s: *const Surface, buf: *[limits.sections]Section) []const Section {
    const n = @min(s.sections.len, limits.sections);
    @memcpy(buf[0..n], s.sections[0..n]);
    std.mem.sort(Section, buf[0..n], {}, struct {
        fn lt(_: void, a: Section, b: Section) bool {
            return a.y < b.y;
        }
    }.lt);
    return buf[0..n];
}

/// interpolação linear de um campo das seções (ordenadas) em y (igual a `_interp_sections`)
pub fn sectionAt(ss: []const Section, y: f64, comptime field: []const u8) f64 {
    if (ss.len == 0) return 0;
    if (y <= ss[0].y) return @field(ss[0], field);
    for (ss[0 .. ss.len - 1], ss[1..]) |a, b| {
        if (y <= b.y) {
            const f = if (b.y > a.y) (y - a.y) / (b.y - a.y) else 0.0;
            return @field(a, field) + f * (@field(b, field) - @field(a, field));
        }
    }
    return @field(ss[ss.len - 1], field);
}

/// amarrações da GUI (`Aircraft.apply_constraints`): cauda na ponta do tubo
pub fn tailOnBoom(ac: *const Aircraft, s: *const Surface) struct { x: f64, z: f64 } {
    const isTail = std.mem.eql(u8, s.role, "htail") or std.mem.eql(u8, s.role, "vtail");
    if (ac.boom.enabled and ac.boom.attach_tail and isTail and s.sections.len > 0) {
        var root = s.sections[0];
        for (s.sections) |q| {
            if (q.y < root.y) root = q;
        }
        const b = ac.boom;
        return .{ .x = b.xEnd() + root.chord, .z = if (std.mem.eql(u8, s.role, "htail")) b.z else b.z - b.diameter / 2 };
    }
    return .{ .x = s.x, .z = s.z };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

const minimal =
    \\{"aeronave": {"name": "teste", "surfaces": [{"name": "asa", "sections": [{"y": 0, "chord": 0.3}, {"y": 1, "chord": 0.2}]}]}}
;

test "lê o arquivo mínimo e ignora campos desconhecidos" {
    var d: Diag = .{};
    var l = try parse(testing.allocator, minimal, &d);
    defer l.deinit();
    try testing.expectEqualStrings("teste", l.ac.name);
    try testing.expectEqual(@as(f64, 1), semispan(&l.ac.surfaces[0]));
    var buf: [limits.sections]Section = undefined;
    try testing.expectApproxEqAbs(@as(f64, 0.25), sectionAt(sortedSections(&l.ac.surfaces[0], &buf), 0.5, "chord"), 1e-12);
}

test "erros esperados, com mensagem" {
    var d: Diag = .{};
    try testing.expectError(error.NotJson, parse(testing.allocator, "{", &d));
    try testing.expectError(error.NoAircraft, parse(testing.allocator, "[1,2]", &d));
    try testing.expectError(error.TooFewSections, parse(testing.allocator,
        \\{"surfaces": [{"name": "asa", "sections": [{"y": 0}]}]}
    , &d));
    try testing.expect(std.mem.indexOf(u8, d.text(), "asa") != null);
    try testing.expectError(error.NotPositive, parse(testing.allocator,
        \\{"surfaces": [{"name": "EH", "sections": [{"y": 0, "chord": -1}, {"y": 1}]}]}
    , &d));
    try testing.expectError(error.BadField, parse(testing.allocator,
        \\{"surfaces": [{"name": 3}]}
    , &d));
    try testing.expectError(error.TooLarge, parse(testing.allocator,
        \\{"surfaces": [], "fuselage": {"enabled": true, "x_nose": 1e9}}
    , &d));
}

fn fuzzParse(_: void, src: *fz.Src) anyerror!void {
    // bytes quaisquer: só pode dar um dos erros previstos (ou ler), nunca travar nem vazar memória
    var buf: [1024]u8 = undefined;
    const n = src.bytes(&buf);
    var d: Diag = .{};
    var l = parse(testing.allocator, buf[0..n], &d) catch |e| {
        try testing.expect(d.len > 0 or e == error.OutOfMemory);
        return;
    };
    l.deinit();
}

test "fuzz: leitura de bytes quaisquer" {
    try fz.check({}, fuzzParse, .{ .corpus = &.{minimal} });
}

fn fuzzValues(_: void, src: *fz.Src) anyerror!void {
    // estrutura válida com números quaisquer: validate aceita ou dá erro, e o que passa é finito
    var secs: [4]Section = undefined;
    for (&secs) |*q| q.* = .{ .y = src.any(), .chord = src.any(), .x_offset = src.any(), .twist = src.any() };
    const ctl = [_]Control{.{ .chord_frac = src.any(), .span_start = src.any(), .span_end = src.any() }};
    const surf = [_]Surface{.{ .sections = secs[0..src.int(u8, 0, 4)], .controls = &ctl, .dihedral = src.any() }};
    const ac: Aircraft = .{ .surfaces = &surf };
    var d: Diag = .{};
    validate(&ac, &d) catch return;
    for (surf[0].sections) |q| try testing.expect(std.math.isFinite(q.chord) and q.chord > 0);
}

test "fuzz: valores quaisquer na estrutura" {
    try fz.check({}, fuzzValues, .{});
}
