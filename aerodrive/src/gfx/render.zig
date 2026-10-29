//! Desenho com raylib (pelo raylib-zig) — a única parte que conhece a biblioteca gráfica, junto
//! com `ui/` e as telas. Trocar o raylib = reescrever estes arquivos; modelo, poses, câmeras e
//! física não mudam.
//!
//! As malhas sobem uma vez para a GPU (no corpo). A cada quadro cada peça recebe a matriz
//! `tela ← NED ← corpo ← driver` (`pose.zig`). Sombreamento igual ao da GUI: duas faces,
//! luz presa à câmera, cor × (0,45 + 0,6 |n·L|).
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");
const pose = @import("pose.zig");
const cam = @import("../camera/camera.zig");
const field = @import("../world/field.zig");
const platform = @import("../sys/platform.zig");

const V3 = v3.V3;

// ------------------------------------------------------------------ NED -> tela (raylib: y para cima)
// (x, y, z)_tela = (e, −d, −n): uma rotação própria (det = +1). A única conversão do programa.
const C: v3.M3 = .{ .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ -1, 0, 0 } };

fn f32_(x: f64) f32 {
    return @floatCast(x);
}

pub fn toScreen(p: V3) rl.Vector3 {
    const q = v3.apply(C, p);
    return .{ .x = f32_(q[0]), .y = f32_(q[1]), .z = f32_(q[2]) };
}

/// matriz do raylib para v_tela = C (R v + t)
pub fn matrix(r: pose.Rigid) rl.Matrix {
    const A = v3.matmul(C, r.R);
    const t = v3.apply(C, r.t);
    return .{
        .m0 = f32_(A[0][0]), .m4 = f32_(A[0][1]), .m8 = f32_(A[0][2]), .m12 = f32_(t[0]),
        .m1 = f32_(A[1][0]), .m5 = f32_(A[1][1]), .m9 = f32_(A[1][2]), .m13 = f32_(t[1]),
        .m2 = f32_(A[2][0]), .m6 = f32_(A[2][1]), .m10 = f32_(A[2][2]), .m14 = f32_(t[2]),
        .m3 = 0, .m7 = 0, .m11 = 0, .m15 = 1,
    };
}

pub fn camera3d(v: cam.View) rl.Camera3D {
    return .{ .position = toScreen(v.eye), .target = toScreen(v.target), .up = toScreen(v.up), .fovy = f32_(v.fov_deg), .projection = .perspective };
}

pub fn color(rgba: [4]f32) rl.Color {
    return .{ .r = @intFromFloat(rgba[0] * 255), .g = @intFromFloat(rgba[1] * 255), .b = @intFromFloat(rgba[2] * 255), .a = @intFromFloat(rgba[3] * 255) };
}

fn color8(c: field.Rgba) rl.Color {
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
}

// ------------------------------------------------------------------ sombreamento da GUI
// O mesmo shader nos dois alvos; só a primeira linha muda: GLSL 3.30 no nativo (OpenGL 3.3) e
// GLSL ES 3.00 no navegador (WebGL 2), que pede a precisão dos float no fragmento.
const glsl_version = if (platform.in_browser) "#version 300 es\nprecision mediump float;\n" else "#version 330\n";

const vs = glsl_version ++
    \\in vec3 vertexPosition;
    \\in vec3 vertexNormal;
    \\uniform mat4 mvp;
    \\uniform mat4 matNormal;
    \\uniform mat4 matView;
    \\out vec3 eyeNormal;
    \\void main() {
    \\    eyeNormal = mat3(matView) * normalize(mat3(matNormal) * vertexNormal);
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;
const fs = glsl_version ++
    \\in vec3 eyeNormal;
    \\uniform vec4 colDiffuse;
    \\out vec4 finalColor;
    \\void main() {
    \\    float p = abs(dot(normalize(eyeNormal), normalize(vec3(0.4, -0.5, 0.75))));
    \\    finalColor = vec4(colDiffuse.rgb * (0.45 + 0.6 * p), colDiffuse.a);
    \\}
;

const Item = struct {
    mesh: rl.Mesh,
    material: rl.Material,
    driver: sk.Driver,
    transparent: bool,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    items: []Item,
    shader: rl.Shader,

    /// sobe as malhas do esqueleto (uma vez)
    pub fn init(gpa: std.mem.Allocator, skel: *const sk.Skeleton) !Scene {
        const shader = try rl.loadShaderFromMemory(vs, fs);
        shader.locs[@intFromEnum(rl.ShaderLocationIndex.matrix_view)] = rl.getShaderLocation(shader, "matView");
        const items = try gpa.alloc(Item, skel.pieces.len);
        for (skel.pieces, items) |p, *it| {
            const rgba = sk.rgba(p.color);
            var mat = try rl.loadMaterialDefault();
            mat.shader = shader;
            mat.maps[@intFromEnum(rl.MaterialMapIndex.albedo)].color = color(rgba);
            it.* = .{ .mesh = upload(p.mesh), .material = mat, .driver = p.driver, .transparent = rgba[3] < 1 };
        }
        return .{ .gpa = gpa, .items = items, .shader = shader };
    }

    pub fn deinit(s: *Scene) void {
        for (s.items) |*it| {
            rl.unloadMesh(it.mesh);
            rl.memFree(@ptrCast(it.material.maps));
        }
        rl.unloadShader(s.shader);
        s.gpa.free(s.items);
    }

    /// desenha a aeronave (dentro de BeginMode3D): opacas primeiro, depois as transparentes.
    /// `payload_world`: a carga LAPES solta (posição no mundo), se já saiu
    pub fn draw(s: *const Scene, body: pose.Rigid, st: pose.DriveState, payload_world: ?pose.Rigid) void {
        inline for (.{ false, true }) |transparent| {
            if (transparent) rl.gl.rlDisableDepthMask();
            for (s.items) |it| {
                if (it.transparent != transparent) continue;
                var r = pose.piece(it.driver, st).then(body);
                if (it.driver == .payload) if (payload_world) |pw| {
                    r = pw;
                };
                if (!r.visible) continue;
                rl.drawMesh(it.mesh, it.material, matrix(r));
            }
            if (transparent) rl.gl.rlEnableDepthMask();
        }
    }
};

/// triângulos soltos (normal por face: sombreamento chapado como na GUI)
fn upload(m: sk.Mesh) rl.Mesh {
    var mesh = std.mem.zeroes(rl.Mesh);
    const nv = m.f.len * 3;
    mesh.vertexCount = @intCast(nv);
    mesh.triangleCount = @intCast(m.f.len);
    const vb: [*]f32 = @ptrCast(@alignCast(rl.memAlloc(@intCast(nv * 3 * @sizeOf(f32)))));
    const nb: [*]f32 = @ptrCast(@alignCast(rl.memAlloc(@intCast(nv * 3 * @sizeOf(f32)))));
    for (m.f, 0..) |t, k| {
        const a = m.v[t[0]];
        const b = m.v[t[1]];
        const d = m.v[t[2]];
        const n = v3.unit(v3.cross(v3.sub(b, a), v3.sub(d, a)), .{ 0, 0, -1 });
        for ([_]V3{ a, b, d }, 0..) |p, j| {
            const i = (k * 3 + j) * 3;
            inline for (0..3) |q| {
                vb[i + q] = f32_(p[q]);
                nb[i + q] = f32_(n[q]);
            }
        }
    }
    mesh.vertices = vb;
    mesh.normals = nb;
    rl.uploadMesh(&mesh, false);
    return mesh;
}

/// chão da exposição nos menus: a grade da GUI (6 m, de 25 em 25 cm), na altura `y` da tela
pub fn hangarGrid(center: V3, below: f64) void {
    const col: rl.Color = .{ .r = 0, .g = 0, .b = 0, .a = 40 };
    const c = toScreen(center);
    const h: f32 = f32_(-below);
    var i: i32 = -12;
    while (i <= 12) : (i += 1) {
        const x: f32 = @as(f32, @floatFromInt(i)) * 0.25;
        rl.drawLine3D(.{ .x = c.x + x, .y = h, .z = c.z - 3 }, .{ .x = c.x + x, .y = h, .z = c.z + 3 }, col);
        rl.drawLine3D(.{ .x = c.x - 3, .y = h, .z = c.z + x }, .{ .x = c.x + 3, .y = h, .z = c.z + x }, col);
    }
}

/// campo de voo: chão, pista, marcas, x_warning, mesa/plataforma e o percurso
pub fn drawField(f: *const field.Field) void {
    const s: f32 = f32_(2 * f.half);
    rl.drawPlane(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = s, .y = s }, color8(field.colors.ground));
    drawBox(f.runway);
    for (f.boxSlice()) |b| drawBox(b);
    for (f.lineSlice()) |l| rl.drawLine3D(toScreen(l.a), toScreen(l.b), color8(l.color));
}

fn drawBox(b: field.Box) void {
    rl.gl.rlPushMatrix();
    const c = toScreen(.{ b.n, b.e, -b.h / 2 });
    rl.gl.rlTranslatef(c.x, c.y, c.z);
    rl.gl.rlRotatef(f32_(-std.math.radiansToDegrees(b.chi)), 0, 1, 0); // rumo: horário visto de cima
    // na tela: x = leste (largura), z = −norte (comprimento)
    rl.drawCubeV(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = f32_(b.W), .y = f32_(b.h), .z = f32_(b.L) }, color8(b.color));
    rl.drawCubeWiresV(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = f32_(b.W), .y = f32_(b.h), .z = f32_(b.L) }, .{ .r = 0, .g = 0, .b = 0, .a = 60 });
    rl.gl.rlPopMatrix();
}

/// rastro (as posições já voadas)
pub fn drawTrail(points: []const V3, col: rl.Color) void {
    if (points.len < 2) return;
    for (points[0 .. points.len - 1], points[1..]) |a, b| rl.drawLine3D(toScreen(a), toScreen(b), col);
}
