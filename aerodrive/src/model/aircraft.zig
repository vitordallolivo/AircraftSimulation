//! Leitura do arquivo do avião salvo pela GUI (`data/aircraft/*.json`, "meus aviões").
//!
//! O arquivo é `{"formato": ..., "aeronave": {...}}` (ou a aeronave direto). Só os campos que o
//! aerodrive usa são lidos; o resto é ignorado. Depois de ler, `validate` confere tudo o que pode
//! quebrar o desenho e devolve um erro com o nome do componente em `Diag` (nunca trava).
const std = @import("std");
const fz = @import("../util/fuzz.zig");

// ------------------------------------------------------------------ esquema (nomes iguais aos do JSON)
/// seção da superfície; `airfoil` null: o perfil da superfície (entre seções as propriedades são interpoladas)
pub const Section = struct { y: f64 = 0, chord: f64 = 0.3, x_offset: f64 = 0, twist: f64 = 0, airfoil: ?Airfoil = null };

/// alguma seção tem perfil próprio
pub fn mixedAirfoils(s: *const Surface) bool {
    for (s.sections) |q| if (q.airfoil != null) return true;
    return false;
}

pub const Control = struct {
    kind: []const u8 = "aileron",
    span_start: f64 = 0.6,
    span_end: f64 = 1.0,
    chord_frac: f64 = 0.25,
    tau: ?f64 = null, // efetividade; null: perfil fino
    deflection: f64 = 0, // deflexão fixa (flape, flaperon baixado)
    mix: ?[3]f64 = null, // [arfagem, rolagem, guinada]; null: a do tipo (kindGains)

    pub fn gains(c: Control) [3]f64 {
        return c.mix orelse kindGains(c.kind);
    }
    /// o que o comando faz, pela mistura (o nome é só nome)
    pub fn role(c: Control) []const u8 {
        const g = c.gains();
        const p = g[0] != 0;
        const r = g[1] != 0;
        const y = g[2] != 0;
        if (p and !r and !y) return "elevator";
        if (!p and r and !y) return "aileron";
        if (!p and !r and y) return "rudder";
        if (p and r and !y) return "elevon";
        if (p and !r and y) return "ruddervator";
        if (!p and !r and !y) return "flap";
        return "mixed";
    }
};

/// a mistura de cada tipo (igual a `KIND_MIX` do aerosim)
pub fn kindGains(kind: []const u8) [3]f64 {
    const eq = std.mem.eql;
    if (eq(u8, kind, "elevator")) return .{ 1, 0, 0 };
    if (eq(u8, kind, "aileron") or eq(u8, kind, "flaperon")) return .{ 0, 1, 0 };
    if (eq(u8, kind, "elevon")) return .{ 1, 1, 0 };
    if (eq(u8, kind, "rudder")) return .{ 0, 0, 1 };
    if (eq(u8, kind, "ruddervator")) return .{ 1, 0, 1 };
    return .{ 0, 0, 0 };
}

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
    cl_alpha: f64 = 5.9,
    cd0: f64 = 0.012,
    oswald: f64 = 0.8,
    enabled: bool = true,
};

pub const Airfoil = struct {
    name: []const u8 = "NACA 0012",
    coords: []const [2]f64 = &.{},
    cl_alpha: f64 = 5.9, // 1/rad (2D)
    alpha0: ?f64 = null, // graus; null: perfil fino
    cl_max: f64 = 1.4,
    cd0: f64 = 0.01,
    cm_ac: ?f64 = null, // null: perfil fino
    inverted: bool = false, // montado de cabeça para baixo: o contorno do arquivo espelhado em y
};

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
    oswald: f64 = 0.85,
    eta: f64 = 1.0,
    downwash: bool = false,
    enabled: bool = true,
    // sobrescritas (null: do perfil e da geometria)
    CLa: ?f64 = null,
    CL0: ?f64 = null,
    CLmax: ?f64 = null,
    CD0: ?f64 = null,
    Cmac: ?f64 = null,
    eps0: ?f64 = null, // graus
    depsda: ?f64 = null,
    mass: f64 = 0,
};

pub const Fuselage = struct {
    enabled: bool = false,
    x_nose: f64 = 0.6,
    length: f64 = 1.2,
    width: f64 = 0.15,
    height: f64 = 0.15,
    z: f64 = 0,
    CDS: f64 = 0.03,
    Cma: f64 = 0.1,
    Cnb: f64 = -0.03,
    CYb: f64 = -0.15,
    aero_point: ?[3]f64 = null,
    mass: f64 = 0,
};
/// tubo: sai de (x_start, y, z) para trás, com inclinação (pitch, + ponta de trás sobe) e abertura
/// (yaw, + ponta de trás para +y). `boom` (um só, com attach_tail) é o formato antigo; `booms` o novo,
/// em que a GUI já grava as superfícies na posição em que ficam presas.
pub const Boom = struct {
    name: []const u8 = "tubo",
    enabled: bool = false,
    x_start: f64 = -0.3,
    y: f64 = 0,
    length: f64 = 0.8,
    diameter: f64 = 0.025,
    z: f64 = 0,
    pitch: f64 = 0,
    yaw: f64 = 0,
    attach_tail: bool = true,
    mass: f64 = 0,

    pub fn start(b: Boom) [3]f64 {
        return .{ b.x_start, b.y, b.z };
    }
    pub fn end(b: Boom) [3]f64 {
        const t = std.math.degreesToRadians(b.pitch);
        const p = std.math.degreesToRadians(b.yaw);
        return .{ b.x_start - b.length * @cos(t) * @cos(p), b.y + b.length * @cos(t) * @sin(p), b.z - b.length * @sin(t) };
    }
    pub fn xEnd(b: Boom) f64 {
        return b.end()[0];
    }
    pub fn middle(b: Boom) [3]f64 {
        const e = b.end();
        return .{ 0.5 * (b.x_start + e[0]), 0.5 * (b.y + e[1]), 0.5 * (b.z + e[2]) };
    }
};
pub const Propeller = struct { D: f64 = 0.381, Ip: f64 = 5.4e-4, mass: f64 = 0.05, J: []const f64 = &.{}, CT: []const f64 = &.{}, CP: []const f64 = &.{} };
pub const Motor = struct { Kv: f64 = 310, Rm: f64 = 0.02, B: f64 = 3e-5, tauc: f64 = 0.015, Imax: f64 = 80, Jm: f64 = 1e-4, mass: f64 = 0.5 };
pub const Battery = struct {
    cells: f64 = 6,
    V_cell: f64 = 3.7,
    Rint: f64 = 0.035,
    capacity_mAh: f64 = 5000,
    mass: f64 = 0.8,

    pub fn voc(b: Battery) f64 {
        return b.cells * b.V_cell;
    }
};
pub const ThrustPoly = struct {
    coefs: []const f64 = &.{},
    x_var: []const u8 = "V",
    y_var: []const u8 = "none",
    gain: f64 = 1,
    rho_exp: f64 = 0,
    rho0: f64 = 1.225,
    xmax: f64 = 0,
    ymax: f64 = 0,
    x_const: f64 = 0,
    y_const: f64 = 0,
};
pub const Propulsion = struct {
    name: []const u8 = "motor",
    x: f64 = 0.55,
    y: f64 = 0,
    z: f64 = 0,
    tilt: f64 = 0,
    tilt_range: f64 = 0, // eixo móvel (graus): tilt + comando·faixa; 0 = fixo
    toe: f64 = 0,
    sense: f64 = 1,
    yaw_mix: f64 = 0,
    thrust_model: []const u8 = "motor",
    thrust_poly: ThrustPoly = .{},
    motor: Motor = .{},
    propeller: Propeller = .{},
    battery: Battery = .{},
    enabled: bool = true,
};
pub const GearLeg = struct { kind: []const u8 = "main", x: f64 = 0, y: f64 = 0, z: f64 = 0.2, k: f64 = 4000, c: f64 = 120 };
pub const Gear = struct {
    layout: []const u8 = "tricycle",
    main_x: f64 = -0.05,
    main_track: f64 = 0.6,
    main_z: f64 = 0.22,
    main_k: f64 = 4000,
    main_c: f64 = 120,
    steer_x: f64 = 0.45,
    steer_z: f64 = 0.22,
    steer_k: f64 = 2000,
    steer_c: f64 = 60,
    tail_skid: bool = true,
    skid_x: f64 = -1.1,
    skid_z: f64 = 0,
    skid_k: f64 = 6000,
    skid_c: f64 = 150,
    custom: []const GearLeg = &.{},
    mu_roll: f64 = 0.04,
    mu_lat: f64 = 0.6,
    mu_brake: f64 = 1.0,
    mu_skid: f64 = 0.35,
    mu_landing: f64 = 0.4,
};
pub const Tank = struct {
    name: []const u8 = "tanque",
    x: f64 = 0.1,
    y: f64 = 0,
    z: f64 = 0.05,
    side: f64 = 0.14,
    volume: f64 = 2.0, // L
    height: f64 = 0.12,
    rho: f64 = 1000,
    zeta: f64 = 0.03,
    shape: []const u8 = "square",

    pub fn baseArea(t: Tank) f64 {
        return if (std.mem.eql(u8, t.shape, "square")) t.side * t.side else std.math.pi * t.side * t.side / 4.0;
    }
    /// altura do líquido (m), pelo volume — igual a `SloshTank.fill`
    pub fn fill(t: Tank) f64 {
        return t.volume / 1000.0 / t.baseArea();
    }
};
pub const Payload = struct {
    enabled: bool = false,
    mass: f64 = 2,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0.08,
    bay: f64 = 0.35,
    Fext_g: f64 = 2,
    mu_b: f64 = 0.3,
    CdS_chute: f64 = 0.45,
};
pub const PointMass = struct { mass: f64 = 0.1, x: f64 = 0, y: f64 = 0, z: f64 = 0 };
pub const Mass = struct {
    base_mass: f64 = 8.39,
    base_cg: [3]f64 = .{ 0, 0, 0 },
    Ixx: f64 = 0.9,
    Iyy: f64 = 1.2,
    Izz: f64 = 1.9,
    Ixz: f64 = 0.04,
    items: []const PointMass = &.{},
    include_propulsion: bool = false,
    include_structure: bool = false,
};
pub const Environment = struct {
    rho: f64 = 1.225,
    wind_speed: f64 = 4,
    wind_from: f64 = 30,
    wind_elev: f64 = 3,
    h_ref: f64 = 10,
    gust: bool = false,
    gust_T: f64 = 1,
    gust_U: []const f64 = &.{ -1, -2, -1 },
};
pub const Takeoff = struct { VR: f64 = 12.5, sR: f64 = 37.5, de0: f64 = 0, de1: f64 = -6, rate_de: f64 = 60, ht: f64 = 2, rate_thr: f64 = 2, h_end: f64 = 6 };
pub const SimSettings = struct { dt: f64 = 1e-3, tmax: f64 = 400, dtlog: f64 = 0.02, Mst: f64 = 50, slosh: bool = true };
/// os mesmos nomes do núcleo (`types.Autopilot`); ângulos em graus no arquivo
pub const Autopilot = struct {
    auto_calibrate: bool = true,
    CL0: f64 = 0.45,
    CLa: f64 = 4.5,
    alpha_max: f64 = 11,
    g_up: f64 = 0.08,
    g_down: f64 = 0.10,
    Khr: f64 = 0.5,
    Kvs: f64 = 0.5,
    Kn_h: f64 = 0.065,
    Kn_hd: f64 = 0.13,
    Kn_ih: f64 = 0.01,
    Kae: f64 = 4,
    KIa: f64 = 4,
    Kfn: f64 = 1.2,
    Lorb: f64 = 50,
    tlead: f64 = 0.8,
    Kthe: f64 = 1.5,
    Kqe: f64 = 0.25,
    KV: f64 = 0.25,
    KIV: f64 = 0.08,
    KHT: f64 = 0.10,
    Dtrim: f64 = 0.55,
    Kchi: f64 = 0.8,
    kvf: f64 = 0.05,
    chi_inf: f64 = 60,
    korb: f64 = 0.5,
    phimax: f64 = 30,
    Kphia: f64 = 2,
    Kpa: f64 = 0.10,
    Kbeta: f64 = 1,
    tau_phi: f64 = 0.3,
    pmax_cmd: f64 = 60,
    Ky: f64 = 0.15,
    Ki: f64 = 0.02,
    Kpsi: f64 = 1.5,
    Kr: f64 = 0.3,
    Kbeq: f64 = 0.5,
    hflare: f64 = 2.5,
    tau_flare: f64 = 1,
    kCL: f64 = 0.95,
    de_max: f64 = 20,
    da_max: f64 = 20,
    dr_max: f64 = 25,
};
pub const Leg = struct {
    kind: []const u8 = "straight", // straight | turn
    length: f64 = 100,
    radius: f64 = 50, // 0 = automático
    angle: f64 = 180,
    side: f64 = 1,
    h: ?f64 = null,
    V: ?f64 = null,
    name: []const u8 = "perna",
    takeoff: bool = false,
    landing: bool = false,
    clearance: f64 = 0,
};
pub const MissionEvent = struct { kind: []const u8 = "drop", leg: i64 = 0, s: f64 = 0 };
pub const Mission = struct {
    name: []const u8 = "missão",
    legs: []const Leg = &.{},
    events: []const MissionEvent = &.{},
    n0: f64 = 0,
    e0: f64 = 0,
    chi0: f64 = 0,
    h0: f64 = 0,
    V0: f64 = 14,
};
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
    boom: Boom = .{}, // formato antigo (um tubo)
    booms: []const Boom = &.{}, // formato novo (quantos quiser)
    propulsion: []const Propulsion = &.{},
    gear: Gear = .{},
    tanks: []const Tank = &.{},
    payload: Payload = .{},
    ballast: Ballast = .{},
    airfield: Airfield = .{},
    mass: Mass = .{},
    environment: Environment = .{},
    takeoff: Takeoff = .{},
    autopilot: Autopilot = .{},
    sim: SimSettings = .{},
    mission: Mission = .{},
    shared_battery: bool = false,
    Sref: ?f64 = null, // null ou 0: da asa
    cref: ?f64 = null,
    bref: ?f64 = null,

    /// os tubos, dos dois formatos: `booms` (novo) ou o `boom` único (antigo)
    pub fn allBooms(ac: *const Aircraft) []const Boom {
        if (ac.booms.len > 0) return ac.booms;
        return @as(*const [1]Boom, &ac.boom);
    }
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
    for (ac.allBooms()) |b| if (b.enabled) {
        inline for (.{ "x_start", "y", "z", "pitch", "yaw" }) |n| try num(diag, "tubo", n, @field(b, n));
        inline for (.{ "length", "diameter" }) |n| try pos(diag, "tubo", n, @field(b, n));
    };
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

test "tubos: formato novo (lista, inclinação, duplo) e o antigo (um só)" {
    var d: Diag = .{};
    var l = try parse(testing.allocator,
        \\{"surfaces": [{"name": "asa", "sections": [{"y": 0, "chord": 0.3}, {"y": 1, "chord": 0.2}]}],
        \\ "booms": [{"enabled": true, "x_start": -0.1, "y": -0.4, "length": 1, "pitch": 10},
        \\           {"enabled": true, "x_start": -0.1, "y": 0.4, "length": 1}]}
    , &d);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.ac.allBooms().len);
    const e = l.ac.allBooms()[0].end();
    try testing.expectApproxEqAbs(-0.1 - @cos(std.math.degreesToRadians(10.0)), e[0], 1e-12);
    try testing.expectApproxEqAbs(-@sin(std.math.degreesToRadians(10.0)), e[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.4), l.ac.allBooms()[1].end()[1], 1e-12);
    var o = try parse(testing.allocator,
        \\{"surfaces": [{"name": "asa", "sections": [{"y": 0, "chord": 0.3}, {"y": 1, "chord": 0.2}]}],
        \\ "boom": {"enabled": true, "x_start": -0.2, "length": 0.9}}
    , &d);
    defer o.deinit();
    try testing.expectEqual(@as(usize, 1), o.ac.allBooms().len);
    try testing.expectApproxEqAbs(@as(f64, -1.1), o.ac.allBooms()[0].xEnd(), 1e-12);
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
