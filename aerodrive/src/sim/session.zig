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
            },
        }
        return a;
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

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
    const a = s.apply(.{ .payload = .{ .enabled = src.boolean() } });
    try testing.expect(std.math.isFinite(a.environment.wind_speed) and a.environment.wind_from >= 0 and a.environment.wind_from < 360);
    try testing.expect(a.airfield.table_height > 0);
}

test "fuzz: sessão" {
    try fz.check({}, fuzzSession, .{});
}
