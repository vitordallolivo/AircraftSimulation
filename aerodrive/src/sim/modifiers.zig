//! Os modificadores do arquivo do avião -> os campos do núcleo (`Params.ground`, `Params.mods`), em Zig.
//!
//! Porta de `aerosim/model/modifiers.py: native`: o primeiro efeito solo ligado vira o método de `Params.ground`
//! (nenhum: desligado), e cada efeito a mais ligado vira um item de `Params.mods` com as superfícies (pelo dono de
//! cada painel, `Surface.owner`), os motores e os ajustes na ordem da struct de ajustes do núcleo. Um tipo que esta
//! versão não conhece é ignorado, como na GUI.
const std = @import("std");
const core = @import("aerosim");
const model = @import("../model/aircraft.zig");

const types = core.types;
const limits = core.limits;
const modifier_types = core.modifiers.types;

/// o que um tipo da GUI é no núcleo
const Entry = union(enum) {
    /// um método do efeito solo (`Params.ground`)
    ground: modifier_types.Ground,
    /// um efeito a mais (`Params.mods`)
    additive: modifier_types.ModifierKind,
};

/// os tipos da GUI (`aerosim/model/modifiers.py: KINDS`) pelo nome
const entries = std.StaticStringMap(Entry).initComptime(.{
    .{ "solo.mccormick", Entry{ .ground = .mccormick } },
    .{ "solo.vlm_imagem", Entry{ .ground = .vlm_image } },
    .{ "esteira.disco", Entry{ .additive = .slipstream_disk } },
    .{ "interferencia.asas", Entry{ .additive = .wing_interference } },
    .{ "comando.momento_flape", Entry{ .additive = .flap_moment } },
});

/// a lista do arquivo, ou o padrão da GUI (só o efeito solo de McCormick) quando o arquivo não tem a chave
fn listOf(aircraft: *const model.Aircraft) []const model.Modifier {
    const default = [_]model.Modifier{.{}};
    return aircraft.modifiers orelse &default;
}

/// escreve `ground`, `n_mod` e `mods` em `params`; os painéis já estão lá, com o dono (índice em `aircraft.surfaces`)
pub fn fill(aircraft: *const model.Aircraft, params: *types.Params) void {
    params.ground = .off;
    var ground_found = false;
    var count: usize = 0;
    for (listOf(aircraft)) |*modifier| {
        if (!modifier.enabled) continue;
        const entry = entries.get(modifier.kind) orelse continue;
        switch (entry) {
            .ground => |method| if (!ground_found) {
                params.ground = method;
                ground_found = true;
                if (method == .vlm_image) params.ground_settings = groundSettings(modifier);
            },
            .additive => |kind| {
                if (count >= limits.max_mods) continue;
                if (item(aircraft, params, modifier, kind)) |built| {
                    params.mods[count] = built;
                    count += 1;
                }
            },
        }
    }
    params.n_mod = @intCast(count);
}

/// a malha, as alturas e os α da tabela do chão pelo VLM ("malha_corda", "malha_envergadura", "altura_1".."altura_9"
/// em envergaduras, "alpha_1".."alpha_6" e "alpha_induzido" em graus); o que falta fica no padrão do núcleo
pub fn groundSettings(modifier: *const model.Modifier) types.GroundSettings {
    var settings: types.GroundSettings = .{};
    settings.chordwise = @intFromFloat(@round(modifier.value("malha_corda", @floatFromInt(settings.chordwise))));
    settings.spanwise = @intFromFloat(@round(modifier.value("malha_envergadura", @floatFromInt(settings.spanwise))));
    var name: [16]u8 = undefined;
    for (&settings.heights, 1..) |*height, k| height.* = modifier.value(std.fmt.bufPrint(&name, "altura_{d}", .{k}) catch unreachable, height.*);
    for (&settings.alphas, 1..) |*alpha, k| alpha.* = modifier.value(std.fmt.bufPrint(&name, "alpha_{d}", .{k}) catch unreachable, alpha.*);
    settings.induced_alpha = modifier.value("alpha_induzido", settings.induced_alpha);
    return settings;
}

/// um efeito a mais como item do núcleo; null quando não pega nenhum painel
fn item(aircraft: *const model.Aircraft, params: *const types.Params, modifier: *const model.Modifier, kind: modifier_types.ModifierKind) ?types.Modifier {
    var built: types.Modifier = .{ .kind = kind };
    switch (kind) {
        .slipstream_disk => {
            built.flags.axial = modifier.value("axial", 1) != 0;
            built.flags.swirl = modifier.value("giro", 1) != 0;
            store(&built, modifier_types.SlipstreamSettings{
                .axial_gain = modifier.value("ganho_axial", 1),
                .swirl_gain = modifier.value("ganho_giro", 1),
            });
        },
        .wing_interference => store(&built, modifier_types.InterferenceSettings{ .gain = modifier.value("ganho", 1) }),
        .flap_moment => store(&built, modifier_types.FlapMomentSettings{ .factor = modifier.value("fator", 0.85) }),
        else => {},
    }
    var panels: modifier_types.PanelSet = .initEmpty();
    if (kind == .wing_interference) {
        // as asas da configuração: cada uma sente as outras; uma asa só, nada a fazer
        var wings: usize = 0;
        for (aircraft.surfaces, 0..) |*surface, index| {
            if (!inWingGroup(aircraft, surface) or !targeted(modifier, surface.name)) continue;
            wings += 1;
            markOwner(params, index, &panels);
        }
        if (wings < 2) return null;
    } else if (modifier.targets.len > 0) {
        for (aircraft.surfaces, 0..) |*surface, index| if (targeted(modifier, surface.name)) markOwner(params, index, &panels);
        if (panels.mask == 0) return null;
    }
    built.surf_mask = .{ @bitCast(@as(u32, @truncate(panels.mask))), @bitCast(@as(u32, @truncate(panels.mask >> 32))) };
    var props: modifier_types.PropSet = .initEmpty();
    for (modifier.props) |prop| if (prop >= 0 and prop < params.n_prop) props.set(@intCast(prop));
    built.prop_mask = @bitCast(props.mask);
    return built;
}

/// os ajustes nos primeiros `params` do item, na ordem da struct de ajustes
fn store(built: *types.Modifier, settings: anytype) void {
    const bytes = std.mem.asBytes(&settings);
    @memcpy(std.mem.asBytes(&built.params)[0..bytes.len], bytes);
}

/// o modificador pega a superfície `name`? (sem superfícies marcadas: pega todas)
fn targeted(modifier: *const model.Modifier, name: []const u8) bool {
    if (modifier.targets.len == 0) return true;
    for (modifier.targets) |target| if (std.mem.eql(u8, target, name)) return true;
    return false;
}

/// a superfície é uma das asas ligadas à asa principal (`Aircraft.wing_group` da GUI; sem grupo, só ela)
fn inWingGroup(aircraft: *const model.Aircraft, surface: *const model.Surface) bool {
    const main = for (aircraft.surfaces) |*candidate| {
        if (candidate.enabled and std.mem.eql(u8, candidate.role, "wing")) break candidate;
    } else return false;
    if (main.group.len == 0) return surface == main;
    return surface.enabled and std.mem.eql(u8, surface.role, "wing") and std.mem.eql(u8, surface.group, main.group);
}

/// marca os painéis cujo dono é a superfície `owner`
fn markOwner(params: *const types.Params, owner: usize, panels: *modifier_types.PanelSet) void {
    for (params.surf[0..@intCast(params.n_surf)], 0..) |panel, index| {
        if (panel.owner == @as(i32, @intCast(owner)) and index < 64) panels.set(index);
    }
}

const testing = std.testing;

test "sem a chave no arquivo: o efeito solo de McCormick e nada mais" {
    var params: types.Params = .{};
    fill(&.{}, &params);
    try testing.expectEqual(modifier_types.Ground.mccormick, params.ground);
    try testing.expectEqual(@as(i32, 0), params.n_mod);
}

test "lista vazia: solo desligado; interferência só com duas asas no grupo" {
    var params: types.Params = .{};
    params.n_surf = 3;
    params.surf[0].owner = 0;
    params.surf[1].owner = 1;
    params.surf[2].owner = 2;
    const surfaces = [_]model.Surface{
        .{ .name = "asa", .group = "par" },
        .{ .name = "asa 2", .group = "par" },
        .{ .name = "profundor", .role = "htail" },
    };
    const interference = [_]model.Modifier{.{ .kind = "interferencia.asas" }};
    fill(&.{ .surfaces = &surfaces, .modifiers = &interference }, &params);
    try testing.expectEqual(modifier_types.Ground.off, params.ground);
    try testing.expectEqual(@as(i32, 1), params.n_mod);
    try testing.expectEqual(modifier_types.ModifierKind.wing_interference, params.mods[0].kind);
    try testing.expectEqual(@as(i32, 0b011), params.mods[0].surf_mask[0]);
    try testing.expectEqual(@as(f64, 1), params.mods[0].settings(modifier_types.InterferenceSettings).gain);

    const alone = [_]model.Surface{.{ .name = "asa" }};
    fill(&.{ .surfaces = &alone, .modifiers = &interference }, &params);
    try testing.expectEqual(@as(i32, 0), params.n_mod);
}

test "esteira: os ajustes e os flags pelo nome" {
    var params: types.Params = .{};
    var settings: std.json.ArrayHashMap(f64) = .{};
    defer settings.deinit(testing.allocator);
    try settings.map.put(testing.allocator, "giro", 0);
    try settings.map.put(testing.allocator, "ganho_axial", 1.2);
    const slipstream = [_]model.Modifier{.{ .kind = "esteira.disco", .params = settings }};
    fill(&.{ .modifiers = &slipstream }, &params);
    try testing.expectEqual(@as(i32, 1), params.n_mod);
    try testing.expect(params.mods[0].flags.axial and !params.mods[0].flags.swirl);
    try testing.expectEqual(@as(f64, 1.2), params.mods[0].settings(modifier_types.SlipstreamSettings).axial_gain);
}
