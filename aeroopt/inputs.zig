//! O catálogo das entradas do aeroopt: tudo o que se escolhe nas etapas do projeto (a chave do `.opt.json`, o
//! nome na tela, a unidade, a faixa de sempre, o grupo e de onde vem a lista). Os rótulos e a ordem dos grupos são os
//! da tela antiga, para o problema aberto aparecer igual.
const std = @import("std");
const problem = @import("problem.zig");

/// o grupo de uma entrada (o botão "isolar" e as abas do submenu Variáveis)
pub const Group = enum {
    wing,
    tail,
    power,
    requirements,
    rules,

    /// o nome do grupo na tela e no `.opt.json`
    pub fn label(group: Group) []const u8 {
        return switch (group) {
            .wing => "asa",
            .tail => "empenagem",
            .power => "motores, carga e trem",
            .requirements => "requisitos",
            .rules => "regras e massas",
        };
    }

    /// o grupo com este nome (`null` para um nome que não é de grupo)
    pub fn fromLabel(name: []const u8) ?Group {
        inline for (std.meta.fields(Group)) |field| {
            const group: Group = @enumFromInt(field.value);
            if (std.mem.eql(u8, group.label(), name)) return group;
        }
        return null;
    }
};

/// de onde vêm as opções de uma lista
pub const Source = enum { none, choices, airfoils, yes_no, motors, propellers, batteries };

/// uma entrada do projeto que pode virar variável
pub const Input = struct {
    key: []const u8,
    path: []const u8, // onde fica no projeto da sprint: "<parte>.<campo>" ("wing_draft.span")
    label: []const u8,
    unit: []const u8 = "",
    kind: problem.VariableKind = .continuous,
    lower: f64 = 0,
    upper: f64 = 1,
    step: f64 = 0,
    group: Group,
    source: Source = .none,
    choices: []const []const u8 = &.{},
};

/// todas as entradas, na ordem da tela
pub const all = [_]Input{
    .{ .key = "wing.span", .path = "wing_draft.span", .label = "envergadura", .unit = "m", .lower = 1.0, .upper = 3.0, .step = 0.02, .group = .wing },
    .{ .key = "wing.area", .path = "wing_draft.area", .label = "área da asa", .unit = "m²", .lower = 0.3, .upper = 1.5, .step = 0.01, .group = .wing },
    .{ .key = "wing.taper", .path = "wing_draft.taper", .label = "afilamento", .lower = 0.3, .upper = 1.0, .step = 0.02, .group = .wing },
    .{ .key = "wing.rect_frac", .path = "wing_draft.rect_frac", .label = "trecho retangular", .lower = 0.0, .upper = 1.0, .step = 0.05, .group = .wing },
    .{ .key = "wing.alpha_cruise", .path = "wing_draft.alpha_cruise", .label = "ângulo de cruzeiro", .unit = "°", .lower = -2.0, .upper = 6.0, .step = 0.25, .group = .wing },
    .{ .key = "wing.airfoil", .path = "wing_draft.airfoil", .label = "perfil da asa (raiz)", .kind = .list, .group = .wing, .source = .airfoils },
    .{ .key = "wing.airfoil_tip", .path = "wing_draft.airfoil_tip", .label = "perfil da ponta (vazio = o da raiz)", .kind = .list, .group = .wing, .source = .airfoils },
    .{ .key = "wing.chord", .path = "wing_draft.chord", .label = "corda da raiz", .unit = "m", .lower = 0.03, .upper = 3.0, .step = 0.005, .group = .wing },
    .{ .key = "wing.sweep", .path = "wing_draft.sweep", .label = "enflechamento (c/4)", .unit = "°", .lower = -10.0, .upper = 45.0, .step = 0.5, .group = .wing },
    .{ .key = "wing.twist", .path = "wing_draft.twist", .label = "torção na ponta", .unit = "°", .lower = -8.0, .upper = 4.0, .step = 0.25, .group = .wing },
    .{ .key = "wing.dihedral", .path = "wing_draft.dihedral", .label = "diedro", .unit = "°", .lower = -5.0, .upper = 15.0, .step = 0.5, .group = .wing },
    .{ .key = "tail.wing2_dx", .path = "tail_draft.wing2_dx", .label = "recuo da segunda asa", .unit = "m", .lower = -3.0, .upper = 3.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.wing2_dz", .path = "tail_draft.wing2_dz", .label = "desnível da segunda asa", .unit = "m", .lower = -1.0, .upper = 1.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.wing2_di", .path = "tail_draft.wing2_di", .label = "decalagem da segunda asa", .unit = "°", .lower = -12.0, .upper = 8.0, .step = 0.25, .group = .tail },
    .{ .key = "tail.wing2_dy", .path = "tail_draft.wing2_dy", .label = "deslocamento lateral da segunda asa", .unit = "m", .lower = -3.0, .upper = 3.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.wing2_join", .path = "tail_draft.wing2_join", .label = "pontas ligadas à segunda asa", .kind = .list, .group = .tail, .source = .yes_no, .choices = &.{ "sim", "não" } },
    .{ .key = "tail.wing2_area", .path = "tail_draft.wing2_area", .label = "área da segunda asa / da primeira", .lower = 0.5, .upper = 2.5, .step = 0.05, .group = .tail },
    .{ .key = "tail.wing2_span", .path = "tail_draft.wing2_span", .label = "envergadura da segunda asa / da primeira", .lower = 0.5, .upper = 2.5, .step = 0.05, .group = .tail },
    .{ .key = "tail.wing2_sweep", .path = "tail_draft.wing2_sweep", .label = "enflechamento a mais na segunda asa", .unit = "°", .lower = 0.0, .upper = 40.0, .step = 0.5, .group = .tail },
    .{ .key = "tail.wing2_airfoil", .path = "tail_draft.wing2_airfoil", .label = "perfil da segunda asa", .kind = .list, .group = .tail, .source = .airfoils },
    .{ .key = "tail.tandem_pitch", .path = "tail_draft.tandem_pitch", .label = "arfagem do tandem", .kind = .list, .group = .tail, .source = .choices, .choices = &.{ "asa de trás", "asa da frente", "as duas" } },
    .{ .key = "tail.tip_fin", .path = "tail_draft.tip_fin", .label = "deriva na ponta (altura)", .unit = "m", .lower = 0.0, .upper = 0.5, .step = 0.01, .group = .tail },
    .{ .key = "tail.tip_fin_chord", .path = "tail_draft.tip_fin_chord", .label = "deriva na ponta: corda", .lower = 0.2, .upper = 1.2, .step = 0.05, .group = .tail },
    .{ .key = "tail.tip_fin_where", .path = "tail_draft.tip_fin_where", .label = "deriva na ponta: onde", .kind = .list, .group = .tail, .source = .choices, .choices = &.{ "asa de trás", "asa da frente" } },
    .{ .key = "tail.layout", .path = "tail_draft.layout", .label = "cauda", .kind = .list, .group = .tail, .source = .choices, .choices = &.{ "convencional", "em V", "sem cauda", "em H" } },
    .{ .key = "tail.arm", .path = "tail_draft.arm", .label = "braço da cauda", .unit = "m", .lower = 0.2, .upper = 3.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.arm_from", .path = "tail_draft.arm_from", .label = "braço medido do", .kind = .list, .group = .tail, .source = .choices, .choices = &.{ "CA da asa", "CG de projeto" } },
    .{ .key = "tail.VH", .path = "tail_draft.VH", .label = "volume de cauda horizontal V_H", .lower = 0.1, .upper = 1.2, .step = 0.01, .group = .tail },
    .{ .key = "tail.VV", .path = "tail_draft.VV", .label = "volume de cauda vertical V_V", .lower = 0.005, .upper = 0.15, .step = 0.002, .group = .tail },
    .{ .key = "tail.AR_h", .path = "tail_draft.AR_h", .label = "alongamento da EH", .lower = 1.0, .upper = 10.0, .step = 0.1, .group = .tail },
    .{ .key = "tail.AR_v", .path = "tail_draft.AR_v", .label = "alongamento da EV", .lower = 0.5, .upper = 5.0, .step = 0.1, .group = .tail },
    .{ .key = "tail.taper_h", .path = "tail_draft.taper_h", .label = "afilamento da EH", .lower = 0.3, .upper = 1.0, .step = 0.05, .group = .tail },
    .{ .key = "tail.taper_v", .path = "tail_draft.taper_v", .label = "afilamento da EV", .lower = 0.3, .upper = 1.0, .step = 0.05, .group = .tail },
    .{ .key = "tail.airfoil", .path = "tail_draft.tail_airfoil", .label = "perfil da EH", .kind = .list, .group = .tail, .source = .airfoils },
    .{ .key = "tail.tail_inverted", .path = "tail_draft.tail_inverted", .label = "EH invertida", .kind = .list, .group = .tail, .source = .yes_no, .choices = &.{ "sim", "não" } },
    .{ .key = "tail.vairfoil", .path = "tail_draft.vtail_airfoil", .label = "perfil da EV", .kind = .list, .group = .tail, .source = .airfoils },
    .{ .key = "tail.elevator", .path = "tail_draft.elevator", .label = "profundor (fração da corda)", .lower = 0.1, .upper = 0.6, .step = 0.01, .group = .tail },
    .{ .key = "tail.rudder", .path = "tail_draft.rudder", .label = "leme (fração da corda)", .lower = 0.1, .upper = 0.6, .step = 0.01, .group = .tail },
    .{ .key = "tail.aileron_start", .path = "tail_draft.aileron_start", .label = "aileron: início", .lower = 0.0, .upper = 0.95, .step = 0.01, .group = .tail },
    .{ .key = "tail.aileron_end", .path = "tail_draft.aileron_end", .label = "aileron: fim", .lower = 0.1, .upper = 1.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.aileron_chord", .path = "tail_draft.aileron_chord", .label = "aileron (fração da corda)", .lower = 0.1, .upper = 0.5, .step = 0.01, .group = .tail },
    .{ .key = "tail.flap_moment", .path = "tail_draft.flap_moment", .label = "momento próprio dos comandos", .kind = .list, .group = .tail, .source = .yes_no, .choices = &.{ "sim", "não" } },
    .{ .key = "tail.sm_target", .path = "tail_draft.sm_target", .label = "margem estática desejada", .unit = "% CMA", .lower = 2.0, .upper = 40.0, .step = 0.5, .group = .tail },
    .{ .key = "tail.sm_min", .path = "tail_draft.sm_min", .label = "margem estática mínima", .unit = "% CMA", .lower = 0.0, .upper = 20.0, .step = 0.5, .group = .tail },
    .{ .key = "tail.tail_eta", .path = "tail_draft.tail_eta", .label = "η da cauda", .lower = 0.5, .upper = 1.0, .step = 0.01, .group = .tail },
    .{ .key = "tail.boom_diameter", .path = "tail_draft.boom_diameter", .label = "diâmetro do tubo", .unit = "m", .lower = 0.005, .upper = 0.1, .step = 0.001, .group = .tail },
    .{ .key = "tail.boom_pitch", .path = "tail_draft.boom_pitch", .label = "inclinação do tubo", .unit = "°", .lower = -10.0, .upper = 20.0, .step = 0.5, .group = .tail },
    .{ .key = "power.motor", .path = "power_draft.motor", .label = "motor", .kind = .list, .group = .power, .source = .motors },
    .{ .key = "power.propeller", .path = "power_draft.propeller", .label = "hélice", .kind = .list, .group = .power, .source = .propellers },
    .{ .key = "power.layout", .path = "power_draft.layout", .label = "motores (arranjo)", .kind = .list, .group = .power, .source = .choices, .choices = &.{ "tratora no nariz", "dois motores na asa", "propulsora atrás da asa", "livre: nariz + asa + atrás" } },
    .{ .key = "power.tilt", .path = "power_draft.tilt", .label = "inclinação do motor", .unit = "°", .lower = 0.0, .upper = 12.0, .step = 0.5, .group = .power },
    .{ .key = "power.motors", .path = "power_draft.wing_motors", .label = "nº de motores (o arranjo manda: nariz/propulsora 1, asa aos pares)", .kind = .integer, .lower = 1.0, .upper = 8.0, .step = 2.0, .group = .power },
    .{ .key = "power.battery", .path = "power_draft.battery", .label = "bateria", .kind = .list, .group = .power, .source = .batteries },
    .{ .key = "power.motor_y", .path = "power_draft.motor_y", .label = "afastamento dos motores", .unit = "m", .lower = 0.0, .upper = 1.5, .step = 0.01, .group = .power },
    .{ .key = "power.nose_motors", .path = "power_draft.nose_motors", .label = "motores no nariz", .kind = .integer, .lower = 0.0, .upper = 1.0, .step = 1.0, .group = .power },
    .{ .key = "power.rear_motors", .path = "power_draft.rear_motors", .label = "motores atrás", .kind = .integer, .lower = 0.0, .upper = 1.0, .step = 1.0, .group = .power },
    .{ .key = "power.lapes", .path = "power_draft.lapes", .label = "tem LAPES", .kind = .list, .group = .power, .source = .yes_no, .choices = &.{ "sim", "não" } },
    .{ .key = "power.n_lapes", .path = "power_draft.n_lapes", .label = "quantas cargas LAPES", .kind = .integer, .lower = 1.0, .upper = 6.0, .step = 1.0, .group = .power },
    .{ .key = "power.liquid", .path = "power_draft.liquid", .label = "tem carga líquida", .kind = .list, .group = .power, .source = .yes_no, .choices = &.{ "sim", "não" } },
    .{ .key = "power.n_tanks", .path = "power_draft.n_tanks", .label = "quantos tanques", .kind = .integer, .lower = 1.0, .upper = 4.0, .step = 1.0, .group = .power },
    .{ .key = "power.gear", .path = "power_draft.gear", .label = "trem", .kind = .list, .group = .power, .source = .choices, .choices = &.{ "triciclo", "convencional" } },
    .{ .key = "power.x_tdp", .path = "power_draft.x_tdp", .label = "x_TDP: trem principal ao CG", .unit = "m", .lower = 0.0, .upper = 0.6, .step = 0.005, .group = .power },
    .{ .key = "power.x_payload", .path = "power_draft.x_payload", .label = "x da carga paga ao CG", .unit = "m", .lower = -0.5, .upper = 0.5, .step = 0.005, .group = .power },
    .{ .key = "power.x_tdn", .path = "power_draft.x_tdn", .label = "x_TDN: bequilha à frente do CG", .unit = "m", .lower = 0.0, .upper = 1.5, .step = 0.005, .group = .power },
    .{ .key = "power.gear_h", .path = "power_draft.gear_h", .label = "altura do trem", .unit = "m", .lower = 0.0, .upper = 1.0, .step = 0.005, .group = .power },
    .{ .key = "power.ground_pitch", .path = "power_draft.ground_pitch", .label = "atitude no chão", .unit = "°", .lower = 0.0, .upper = 15.0, .step = 0.5, .group = .power },
    .{ .key = "req.V_cruise", .path = "requirements.V_cruise", .label = "velocidade de cruzeiro", .unit = "m/s", .lower = 10.0, .upper = 25.0, .step = 0.5, .group = .requirements },
    .{ .key = "req.mass", .path = "requirements.mass", .label = "massa estimada (ponto de partida)", .unit = "kg", .lower = 2.0, .upper = 20.0, .step = 0.1, .group = .requirements },
    .{ .key = "req.density_altitude", .path = "requirements.density_altitude", .label = "altitude-densidade (AD)", .unit = "m", .lower = -500.0, .upper = 4000.0, .step = 50.0, .group = .requirements },
    .{ .key = "req.mu_roll", .path = "requirements.mu_roll", .label = "atrito de rolamento", .lower = 0.0, .upper = 0.3, .step = 0.005, .group = .requirements },
    .{ .key = "req.V_turn", .path = "requirements.V_turn", .label = "V da curva", .unit = "m/s", .lower = 0.0, .upper = 60.0, .step = 0.5, .group = .requirements },
    .{ .key = "req.mu_brake", .path = "requirements.mu_brake", .label = "atrito na frenagem", .lower = 0.05, .upper = 1.0, .step = 0.05, .group = .requirements },
    .{ .key = "req.obstacle_h", .path = "requirements.obstacle_h", .label = "altura do obstáculo", .unit = "m", .lower = 0.0, .upper = 5.0, .step = 0.05, .group = .requirements },
    .{ .key = "rules.wing_density", .path = "rules.wing_density", .label = "massa da asa por área", .unit = "kg/m²", .lower = 0.1, .upper = 6.0, .step = 0.05, .group = .rules },
    .{ .key = "rules.tail_density", .path = "rules.tail_density", .label = "massa da empenagem por área", .unit = "kg/m²", .lower = 0.1, .upper = 6.0, .step = 0.05, .group = .rules },
    .{ .key = "rules.boom_density", .path = "rules.boom_density", .label = "massa do tubo por metro", .unit = "kg/m", .lower = 0.01, .upper = 2.0, .step = 0.01, .group = .rules },
    .{ .key = "rules.fuselage_width", .path = "rules.fuselage_width", .label = "largura da fuselagem", .unit = "m", .lower = 0.03, .upper = 0.6, .step = 0.01, .group = .rules },
    .{ .key = "rules.fuselage_height", .path = "rules.fuselage_height", .label = "altura da fuselagem", .unit = "m", .lower = 0.03, .upper = 0.6, .step = 0.01, .group = .rules },
    .{ .key = "rules.fuselage_cd_wet", .path = "rules.fuselage_cd_wet", .label = "C_D da fuselagem (área molhada)", .lower = 0.005, .upper = 0.2, .step = 0.005, .group = .rules },
    .{ .key = "rules.fuselage_density", .path = "rules.fuselage_density", .label = "massa da fuselagem por metro", .unit = "kg/m", .lower = 0.05, .upper = 5.0, .step = 0.05, .group = .rules },
    .{ .key = "rules.systems_mass", .path = "rules.systems_mass", .label = "sistemas", .unit = "kg", .lower = 0.0, .upper = 5.0, .step = 0.05, .group = .rules },
    .{ .key = "rules.gear_mass", .path = "rules.gear_mass", .label = "trem de pouso", .unit = "kg", .lower = 0.0, .upper = 5.0, .step = 0.05, .group = .rules },
    .{ .key = "rules.nose_length", .path = "rules.nose_length", .label = "nariz à frente da asa", .unit = "m", .lower = 0.05, .upper = 1.5, .step = 0.01, .group = .rules },
    .{ .key = "rules.wing_z", .path = "rules.wing_z", .label = "altura da asa", .unit = "m", .lower = -0.5, .upper = 0.5, .step = 0.01, .group = .rules },
    .{ .key = "rules.prop_clearance", .path = "rules.prop_clearance", .label = "folga da hélice ao chão", .unit = "m", .lower = 0.0, .upper = 0.5, .step = 0.01, .group = .rules },
    .{ .key = "rules.main_gear_aft", .path = "rules.main_gear_aft", .label = "trem principal atrás do CG", .unit = "m", .lower = 0.0, .upper = 0.5, .step = 0.01, .group = .rules },
    .{ .key = "rules.track", .path = "rules.track", .label = "bitola do trem", .unit = "m", .lower = 0.1, .upper = 2.0, .step = 0.01, .group = .rules },
    .{ .key = "rules.de_max", .path = "rules.de_max", .label = "profundor: curso para cabrar", .unit = "°", .lower = 5.0, .upper = 40.0, .step = 1.0, .group = .rules },
    .{ .key = "rules.de_down", .path = "rules.de_down", .label = "profundor: curso para picar", .unit = "°", .lower = 2.0, .upper = 40.0, .step = 1.0, .group = .rules },
    .{ .key = "rules.da_max", .path = "rules.da_max", .label = "aileron: curso para cima", .unit = "°", .lower = 5.0, .upper = 40.0, .step = 1.0, .group = .rules },
    .{ .key = "rules.da_down", .path = "rules.da_down", .label = "aileron: curso para baixo", .unit = "°", .lower = 2.0, .upper = 40.0, .step = 1.0, .group = .rules },
};

/// a entrada com esta chave
pub fn find(key: []const u8) ?*const Input {
    for (&all) |*item| if (std.mem.eql(u8, item.key, key)) return item;
    return null;
}

/// o nome de uma chave na tela (uma chave fora do catálogo aparece como está)
pub fn label(key: []const u8) []const u8 {
    return if (find(key)) |item| item.label else key;
}

/// o grupo de uma variável: o do catálogo; fora dele, o nome guardado no arquivo
pub fn groupOf(variable: *const problem.Variable) ?Group {
    if (find(variable.key)) |item| return item.group;
    return Group.fromLabel(variable.group);
}

test "catálogo: chaves únicas, rótulos e grupos" {
    for (all, 0..) |item, i| for (all[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, item.key, other.key));
    try std.testing.expectEqualStrings("envergadura", label("wing.span"));
    try std.testing.expectEqual(Group.wing, find("wing.airfoil").?.group);
    try std.testing.expectEqual(Group.power, Group.fromLabel("motores, carga e trem").?);
    try std.testing.expectEqualStrings("x.y", label("x.y"));
}
