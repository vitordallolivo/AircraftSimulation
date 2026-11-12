//! Seção composta de uma viga (longarina, tubo de cauda): a seção é uma soma de partes (alma, mesas, tubos, chapeado),
//! cada uma do seu material. A linha neutra pondera a área pelo módulo, e a rigidez à flexão sai pelo teorema dos
//! eixos paralelos, com o termo próprio de cada parte:
//!
//!     z_LN = Σ E_k A_k z_k / Σ E_k A_k
//!     EI   = Σ E_k (I_k + A_k (z_k − z_LN)²)
//!
//! A tensão normal numa fibra a z, com o momento fletor M (positivo quando a ponta sobe, o que comprime o lado de
//! cima), é σ = −M E (z − z_LN)/EI. A alma leva o cortante inteiro, τ = V/(h t) (a média; a distribuição real tem pico
//! no meio da alma). A margem é a resistência do material sobre a tensão, menos 1, com a resistência de tração ou de
//! compressão conforme o sinal. O fator de segurança entra nas cargas, por quem chama.
//!
//! Fontes: Megson, T. H. G., "Aircraft Structures for Engineering Students", flexão de vigas de seção composta (seção
//! transformada) e eixos paralelos; Gere, J. M. e Timoshenko, S. P., "Mechanics of Materials", vigas compostas.
//! Números das equações a conferir no PDF.
//!
//! O material é sempre do usuário (nunca um padrão): o núcleo só faz a conta com o que recebe.
const std = @import("std");
const fmath = @import("../math/fmath.zig");

/// um material isotrópico (ou o valor na direção da fibra de um ortotrópico): módulos em Pa, densidade em kg/m³ e
/// resistências em Pa (tração, compressão e cisalhamento, todas positivas)
pub const Material = extern struct {
    modulus: f64 = 0, // E
    shear_modulus: f64 = 0, // G
    poisson: f64 = 0.3, // ν
    density: f64 = 0,
    tension: f64 = 0,
    compression: f64 = 0,
    shear: f64 = 0,
};

/// uma parte da seção: o material (índice na lista de materiais), a área, a altura do centroide, o momento de inércia
/// em torno do próprio centroide e a distância do centroide à fibra mais afastada (m, m², m⁴)
pub const SectionPart = extern struct {
    material: i32 = 0,
    _pad: i32 = 0,
    area: f64 = 0,
    z: f64 = 0,
    own_inertia: f64 = 0,
    half_depth: f64 = 0,

    /// um retângulo de largura `width` e altura `height` com o centro em `z` (alma, mesa, chapeado plano)
    pub fn rectangle(material: i32, width: f64, height: f64, z: f64) SectionPart {
        return .{ .material = material, .area = width * height, .z = z, .own_inertia = width * height * height * height / 12, .half_depth = 0.5 * height };
    }

    /// um tubo de diâmetro externo `outer` e interno `inner` com o eixo em `z` (inner = 0: barra maciça)
    pub fn tube(material: i32, outer: f64, inner: f64, z: f64) SectionPart {
        const outer2 = outer * outer;
        const inner2 = inner * inner;
        return .{
            .material = material,
            .area = fmath.pi / 4.0 * (outer2 - inner2),
            .z = z,
            .own_inertia = fmath.pi / 64.0 * (outer2 * outer2 - inner2 * inner2),
            .half_depth = 0.5 * outer,
        };
    }
};

/// o que a seção inteira dá: linha neutra (m), EA (N), EI (N·m²) e a massa por comprimento (kg/m)
pub const SectionProperties = extern struct {
    neutral_z: f64 = 0,
    axial: f64 = 0,
    bending: f64 = 0,
    mass_per_length: f64 = 0,
};

/// a tensão nas duas fibras extremas de uma parte (Pa, + tração) e a margem da pior delas
pub const PartStress = extern struct {
    top: f64 = 0,
    bottom: f64 = 0,
    margin: f64 = 0,
};

pub const Error = error{ NoParts, BadMaterial, NoStiffness };

/// o material da parte, conferindo o índice e o módulo
fn materialOf(materials: []const Material, part: SectionPart) Error!Material {
    if (part.material < 0 or part.material >= materials.len) return error.BadMaterial;
    const material = materials[@intCast(part.material)];
    if (!(material.modulus > 0)) return error.BadMaterial;
    return material;
}

/// a linha neutra, EA, EI e a massa por comprimento da seção `parts`
pub fn properties(materials: []const Material, parts: []const SectionPart) Error!SectionProperties {
    if (parts.len == 0) return error.NoParts;
    var axial: f64 = 0;
    var first_moment: f64 = 0;
    var mass: f64 = 0;
    for (parts) |part| {
        const material = try materialOf(materials, part);
        axial += material.modulus * part.area;
        first_moment += material.modulus * part.area * part.z;
        mass += material.density * part.area;
    }
    if (!(axial > 0)) return error.NoStiffness;
    const neutral = first_moment / axial;
    var bending: f64 = 0;
    for (parts) |part| {
        const material = try materialOf(materials, part);
        const offset = part.z - neutral;
        bending += material.modulus * (part.own_inertia + part.area * offset * offset);
    }
    if (!(bending > 0)) return error.NoStiffness;
    return .{ .neutral_z = neutral, .axial = axial, .bending = bending, .mass_per_length = mass };
}

/// σ = −M E (z − z_LN)/EI numa fibra a `z`, com `moment` positivo levantando a ponta (comprime em cima)
pub fn bendingStress(section: SectionProperties, modulus: f64, moment: f64, z: f64) f64 {
    return -moment * modulus * (z - section.neutral_z) / section.bending;
}

/// resistência sobre tensão menos 1 (tração ou compressão pelo sinal); infinita sem tensão
pub fn normalMargin(material: Material, stress: f64) f64 {
    if (stress == 0) return std.math.inf(f64);
    const allowable = if (stress > 0) material.tension else material.compression;
    return allowable / @abs(stress) - 1;
}

/// as tensões nas fibras extremas de cada parte sob o momento `moment` (N·m), em `out` (um por parte)
pub fn stresses(materials: []const Material, parts: []const SectionPart, section: SectionProperties, moment: f64, out: []PartStress) Error!void {
    for (parts, out[0..parts.len]) |part, *result| {
        const material = try materialOf(materials, part);
        const top = bendingStress(section, material.modulus, moment, part.z + part.half_depth);
        const bottom = bendingStress(section, material.modulus, moment, part.z - part.half_depth);
        result.* = .{ .top = top, .bottom = bottom, .margin = @min(normalMargin(material, top), normalMargin(material, bottom)) };
    }
}

/// o cisalhamento médio da alma, τ = V/(h t), com o cortante `shear` (N) todo nela
pub fn webShear(shear: f64, height: f64, thickness: f64) f64 {
    return shear / (height * thickness);
}

/// a margem ao cisalhamento: resistência sobre |τ| menos 1
pub fn shearMargin(material: Material, stress: f64) f64 {
    if (stress == 0) return std.math.inf(f64);
    return material.shear / @abs(stress) - 1;
}

// ------------------------------------------------------------------ torção
// Rigidez à torção (Megson, "Aircraft Structures for Engineering Students", torção de seções fechadas e abertas;
// a conferir no PDF). Célula fechada (a caixa D com o chapeado até a longarina), Bredt–Batho: GJ = 4 A²/∮ ds/(G t).
// Paredes abertas: GJ = Σ G b t³/3. Tubo: GJ = G π (D⁴ − d⁴)/32.

/// uma parede da seção: o material, o comprimento ao longo do contorno e a espessura (m)
pub const Wall = extern struct {
    material: i32 = 0,
    _pad: i32 = 0,
    length: f64 = 0,
    thickness: f64 = 0,
};

/// GJ (N·m²) da célula fechada de área interna `enclosed` (m²) pelas paredes `walls` (Bredt–Batho)
pub fn closedCellTorsion(materials: []const Material, walls: []const Wall, enclosed: f64) Error!f64 {
    if (walls.len == 0) return error.NoParts;
    var compliance: f64 = 0;
    for (walls) |wall| {
        if (wall.material < 0 or wall.material >= materials.len) return error.BadMaterial;
        const modulus = materials[@intCast(wall.material)].shear_modulus;
        if (!(modulus > 0) or !(wall.thickness > 0)) return error.NoStiffness;
        compliance += wall.length / (modulus * wall.thickness);
    }
    return 4 * enclosed * enclosed / compliance;
}

/// GJ (N·m²) das paredes abertas `walls`, Σ G b t³/3
pub fn openTorsion(materials: []const Material, walls: []const Wall) Error!f64 {
    var stiffness: f64 = 0;
    for (walls) |wall| {
        if (wall.material < 0 or wall.material >= materials.len) return error.BadMaterial;
        stiffness += materials[@intCast(wall.material)].shear_modulus * wall.length * wall.thickness * wall.thickness * wall.thickness / 3;
    }
    return stiffness;
}

/// GJ (N·m²) de um tubo de diâmetros `outer` e `inner` com módulo de cisalhamento `shear_modulus`
pub fn tubeTorsion(shear_modulus: f64, outer: f64, inner: f64) f64 {
    const outer2 = outer * outer;
    const inner2 = inner * inner;
    return shear_modulus * fmath.pi / 32.0 * (outer2 * outer2 - inner2 * inner2);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

/// um material de teste (alumínio 2024-T3, Megson, tabela de propriedades: E = 72 GPa; a conferir no PDF). Só para o
/// teste; o núcleo não tem material padrão
const aluminium: Material = .{ .modulus = 72e9, .shear_modulus = 27e9, .poisson = 0.33, .density = 2770, .tension = 400e6, .compression = 400e6, .shear = 250e6 };

test "seção: retângulo e tubo dão o EI da fórmula fechada" {
    const materials = [_]Material{aluminium};
    const block = [_]SectionPart{SectionPart.rectangle(0, 0.01, 0.03, 0.5)};
    const found = try properties(&materials, &block);
    try testing.expectApproxEqRel(@as(f64, 0.5), found.neutral_z, 1e-12);
    try testing.expectApproxEqRel(aluminium.modulus * 0.01 * 0.03 * 0.03 * 0.03 / 12, found.bending, 1e-12);
    const pipe = [_]SectionPart{SectionPart.tube(0, 0.012, 0.010, 0)};
    const tube_found = try properties(&materials, &pipe);
    try testing.expectApproxEqRel(aluminium.modulus * fmath.pi / 64.0 * (std.math.pow(f64, 0.012, 4) - std.math.pow(f64, 0.010, 4)), tube_found.bending, 1e-12);
    try testing.expectApproxEqRel(aluminium.density * fmath.pi / 4.0 * (0.012 * 0.012 - 0.010 * 0.010), tube_found.mass_per_length, 1e-12);
}

test "seção: o retângulo cortado em duas metades dá o mesmo EI (eixos paralelos)" {
    const materials = [_]Material{aluminium};
    const whole = try properties(&materials, &[_]SectionPart{SectionPart.rectangle(0, 0.02, 0.04, 0)});
    const halves = try properties(&materials, &[_]SectionPart{ SectionPart.rectangle(0, 0.02, 0.02, 0.01), SectionPart.rectangle(0, 0.02, 0.02, -0.01) });
    try testing.expectApproxEqRel(whole.bending, halves.bending, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), halves.neutral_z, 1e-15);
}

test "seção: dois materiais puxam a linha neutra para o mais rígido, e a tensão no topo é −M c/I no homogêneo" {
    const stiff: Material = .{ .modulus = 10 * aluminium.modulus, .tension = 1e9, .compression = 1e9 };
    const materials = [_]Material{ aluminium, stiff };
    // duas mesas iguais em ±0,02 m, a de cima dez vezes mais rígida: z_LN = (10·0,02 − 0,02)/11
    const caps = [_]SectionPart{ SectionPart.rectangle(1, 0.01, 0.002, 0.02), SectionPart.rectangle(0, 0.01, 0.002, -0.02) };
    const found = try properties(&materials, &caps);
    try testing.expectApproxEqRel(@as(f64, 0.02 * 9.0 / 11.0), found.neutral_z, 1e-12);
    // homogêneo: σ_topo = −M (h/2)/I = −6M/(b h²)
    const block = [_]SectionPart{SectionPart.rectangle(0, 0.01, 0.03, 0)};
    const section = try properties(&materials, &block);
    var out: [1]PartStress = undefined;
    try stresses(&materials, &block, section, 10, &out);
    try testing.expectApproxEqRel(-6.0 * 10 / (0.01 * 0.03 * 0.03), out[0].top, 1e-12);
    try testing.expectApproxEqRel(-out[0].top, out[0].bottom, 1e-12);
    try testing.expectApproxEqRel(aluminium.compression / @abs(out[0].top) - 1, out[0].margin, 1e-12);
}

test "seção: sem parte, material fora da lista ou sem módulo dá erro" {
    const materials = [_]Material{aluminium};
    try testing.expectError(error.NoParts, properties(&materials, &[_]SectionPart{}));
    try testing.expectError(error.BadMaterial, properties(&materials, &[_]SectionPart{SectionPart.rectangle(3, 0.01, 0.01, 0)}));
    try testing.expectError(error.BadMaterial, properties(&[_]Material{.{}}, &[_]SectionPart{SectionPart.rectangle(0, 0.01, 0.01, 0)}));
    try testing.expectApproxEqRel(@as(f64, 1000.0 / (0.05 * 0.002)), webShear(1000, 0.05, 0.002), 1e-12);
}
