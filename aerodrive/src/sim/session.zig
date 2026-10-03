//! Sessão de voo: o que o jogador escolhe nos menus antes de voar (cenário, modo, vento, sloshing,
//! LAPES) e como isso muda a cópia do avião que vai para o núcleo. O arquivo do avião não muda.
const std = @import("std");
const model = @import("../model/aircraft.zig");
const fz = @import("../util/fuzz.zig");

pub const Scenario = enum {
    ground,
    table,

    pub fn label(s: Scenario) [:0]const u8 {
        return switch (s) {
            .ground => "Chão",
            .table => "Mesa",
        };
    }
};

pub const Landing = enum {
    ground,
    platform,

    pub fn label(l: Landing) [:0]const u8 {
        return switch (l) {
            .ground => "Chão",
            .platform => "Plataforma",
        };
    }
};

pub const Mode = enum {
    manual,
    autopilot,

    pub fn label(m: Mode) [:0]const u8 {
        return switch (m) {
            .manual => "Manual",
            .autopilot => "Piloto automático",
        };
    }
};

pub const Session = struct {
    scenario: Scenario = .ground,
    landing: Landing = .ground,
    start_mode: Mode = .manual,
    slosh: bool = true, // líquido mexendo (se tiver tanque)
    payload: bool = true, // carga LAPES a bordo (se o avião tiver)
    wind_speed: f64 = 4.0, // m/s a 10 m
    wind_from: f64 = 30.0, // graus: de onde vem (0 = norte, 90 = leste)
    table_height: f64 = 1.0, // m (cenário mesa)
    table_length: f64 = 15.0,

    /// valores fora da faixa voltam para dentro (vindo de arquivo ou de deslizador)
    pub fn sanitize(s: *Session) void {
        const fix = struct {
            fn f(v: f64, lo: f64, hi: f64, d: f64) f64 {
                return if (std.math.isFinite(v)) std.math.clamp(v, lo, hi) else d;
            }
        }.f;
        s.wind_speed = fix(s.wind_speed, 0, 20, 4);
        s.wind_from = @mod(fix(s.wind_from, -1e6, 1e6, 30), 360);
        if (!(s.wind_from < 360)) s.wind_from = 0; // −1e−30 mod 360 arredonda para 360
        s.table_height = fix(s.table_height, 0.1, 5, 1);
        s.table_length = fix(s.table_length, 2, 100, 15);
    }

    /// cópia do avião com as escolhas da sessão (fatias continuam do arquivo)
    pub fn apply(s: Session, ac: model.Aircraft) model.Aircraft {
        var a = ac;
        var ss = s;
        ss.sanitize();
        a.environment.wind_speed = ss.wind_speed;
        a.environment.wind_from = ss.wind_from;
        a.sim.slosh = ss.slosh;
        a.payload.enabled = ac.payload.enabled and ss.payload;
        switch (ss.scenario) {
            .ground => a.airfield.takeoff_from = "chão",
            .table => {
                a.airfield.takeoff_from = "mesa";
                a.airfield.table_height = ss.table_height;
                a.airfield.table_length = ss.table_length;
                // a mesa cabe o trem inteiro: roda de cauda/bequilha atrás e bitola (qualquer avião)
                const g = gearExtent(&ac.gear);
                a.airfield.table_back = @max(ac.airfield.table_back, -g.x_min + 0.3);
                a.airfield.table_width = @max(ac.airfield.table_width, g.track + 0.6);
            },
        }
        a.airfield.landing_on = switch (ss.landing) {
            .ground => "chão",
            .platform => "plataforma",
        };
        return a;
    }
};

/// a roda mais para trás (x mínimo, no corpo) e a maior bitola do trem
pub fn gearExtent(g: *const model.Gear) struct { x_min: f64, track: f64 } {
    var x_min: f64 = @min(g.main_x, g.steer_x);
    if (g.tail_skid) x_min = @min(x_min, g.skid_x);
    var track: f64 = g.main_track;
    for (g.custom) |c| {
        x_min = @min(x_min, c.x);
        track = @max(track, 2 * @abs(c.y));
    }
    if (!std.math.isFinite(x_min) or x_min < -50) x_min = 0;
    if (!std.math.isFinite(track) or track > 50 or track < 0) track = 0;
    return .{ .x_min = @min(x_min, 0), .track = track };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "mesa cabe a roda de cauda e a bitola; pouso na plataforma" {
    const s: Session = .{ .scenario = .table, .landing = .platform };
    const a = s.apply(.{ .gear = .{ .steer_x = -1.15, .main_track = 2.5, .tail_skid = false } });
    try testing.expect(a.airfield.table_back >= 1.45 - 1e-9);
    try testing.expect(a.airfield.table_width >= 3.1 - 1e-9);
    try testing.expectEqualStrings("plataforma", a.airfield.landing_on);
}

test "mesa liga o pad; LAPES só fica se o avião tiver" {
    const s: Session = .{ .scenario = .table, .payload = true, .wind_speed = 99, .wind_from = -90 };
    const a = s.apply(.{ .payload = .{ .enabled = false } });
    try testing.expectEqualStrings("mesa", a.airfield.takeoff_from);
    try testing.expect(!a.payload.enabled);
    try testing.expectEqual(@as(f64, 20), a.environment.wind_speed);
    try testing.expectEqual(@as(f64, 270), a.environment.wind_from);
}

fn fuzzSession(_: void, src: *fz.Src) anyerror!void {
    const s: Session = .{ .scenario = if (src.boolean()) .table else .ground, .slosh = src.boolean(), .payload = src.boolean(), .wind_speed = src.any(), .wind_from = src.any(), .table_height = src.any(), .table_length = src.any() };
    const legs = [_]model.GearLeg{.{ .x = src.any(), .y = src.any() }};
    const a = s.apply(.{ .payload = .{ .enabled = src.boolean() }, .gear = .{ .steer_x = src.any(), .main_x = src.any(), .main_track = src.any(), .custom = legs[0..src.int(u8, 0, 1)] } });
    try testing.expect(std.math.isFinite(a.airfield.table_back) and std.math.isFinite(a.airfield.table_width));
    try testing.expect(std.math.isFinite(a.environment.wind_speed) and a.environment.wind_from >= 0 and a.environment.wind_from < 360);
    try testing.expect(a.airfield.table_height > 0);
}

test "fuzz: sessão" {
    try fz.check({}, fuzzSession, .{});
}
