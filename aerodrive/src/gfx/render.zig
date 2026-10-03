//! Desenho do esqueleto com raylib — a única parte que conhece a biblioteca gráfica (trocar o
//! raylib = reescrever só este arquivo e o `ui`).
//!
//! As malhas sobem uma vez para a GPU (no corpo). A cada quadro cada peça recebe a matriz
//! `tela ← NED ← corpo ← driver` (`pose.zig`). Sombreamento igual ao da GUI: duas faces,
//! luz presa à câmera, cor × (0,45 + 0,6 |n·L|).
const std = @import("std");
const c = @import("c");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");
const pose = @import("pose.zig");
const cam = @import("../camera/camera.zig");

const V3 = v3.V3;

// ------------------------------------------------------------------ NED -> tela (raylib: y para cima)
// (x, y, z)_tela = (e, −d, −n): uma rotação própria (det = +1). A única conversão do programa.
const C: v3.M3 = .{ .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ -1, 0, 0 } };

pub fn toScreen(p: V3) c.Vector3 {
    const q = v3.apply(C, p);
    return .{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) };
}

/// matriz do raylib para v_tela = C (R v + t)
pub fn matrix(r: pose.Rigid) c.Matrix {
    const A = v3.matmul(C, r.R);
    const t = v3.apply(C, r.t);
    const f = struct {
        fn f(x: f64) f32 {
            return @floatCast(x);
        }
    }.f;
    return .{
        .m0 = f(A[0][0]), .m4 = f(A[0][1]), .m8 = f(A[0][2]), .m12 = f(t[0]),
        .m1 = f(A[1][0]), .m5 = f(A[1][1]), .m9 = f(A[1][2]), .m13 = f(t[1]),
        .m2 = f(A[2][0]), .m6 = f(A[2][1]), .m10 = f(A[2][2]), .m14 = f(t[2]),
        .m3 = 0, .m7 = 0, .m11 = 0, .m15 = 1,
    };
}

pub fn camera3d(v: cam.View) c.Camera3D {
    return .{ .position = toScreen(v.eye), .target = toScreen(v.target), .up = toScreen(v.up), .fovy = @floatCast(v.fov_deg), .projection = c.CAMERA_PERSPECTIVE };
}

pub fn color(rgba: [4]f32) c.Color {
    return .{ .r = @intFromFloat(rgba[0] * 255), .g = @intFromFloat(rgba[1] * 255), .b = @intFromFloat(rgba[2] * 255), .a = @intFromFloat(rgba[3] * 255) };
}

// ------------------------------------------------------------------ sombreamento da GUI
const vs =
    \\#version 330
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
const fs =
    \\#version 330
    \\in vec3 eyeNormal;
    \\uniform vec4 colDiffuse;
    \\out vec4 finalColor;
    \\void main() {
    \\    float p = abs(dot(normalize(eyeNormal), normalize(vec3(0.4, -0.5, 0.75))));
    \\    finalColor = vec4(colDiffuse.rgb * (0.45 + 0.6 * p), colDiffuse.a);
    \\}
;

const Item = struct {
    mesh: c.Mesh,
    material: c.Material,
    driver: sk.Driver,
    transparent: bool,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    items: []Item,
    shader: c.Shader,

    /// sobe as malhas do esqueleto (uma vez)
    pub fn init(gpa: std.mem.Allocator, skel: *const sk.Skeleton) !Scene {
        const shader = c.LoadShaderFromMemory(vs, fs);
        shader.locs[@intCast(c.SHADER_LOC_MATRIX_VIEW)] = c.GetShaderLocation(shader, "matView");
        const items = try gpa.alloc(Item, skel.pieces.len);
        for (skel.pieces, items) |p, *it| {
            const rgba = sk.rgba(p.color);
            var mat = c.LoadMaterialDefault();
            mat.shader = shader;
            mat.maps[@intCast(c.MATERIAL_MAP_DIFFUSE)].color = color(rgba);
            it.* = .{ .mesh = upload(p.mesh), .material = mat, .driver = p.driver, .transparent = rgba[3] < 1 };
        }
        return .{ .gpa = gpa, .items = items, .shader = shader };
    }

    pub fn deinit(s: *Scene) void {
        for (s.items) |*it| {
            c.UnloadMesh(it.mesh);
            c.MemFree(it.material.maps);
        }
        c.UnloadShader(s.shader);
        s.gpa.free(s.items);
    }

    /// desenha a aeronave (dentro de BeginMode3D): opacas primeiro, depois as transparentes
    pub fn draw(s: *const Scene, body: pose.Rigid, st: pose.DriveState) void {
        inline for (.{ false, true }) |transparent| {
            if (transparent) c.rlDisableDepthMask();
            for (s.items) |it| {
                if (it.transparent != transparent) continue;
                const r = pose.piece(it.driver, st).then(body);
                if (!r.visible) continue;
                c.DrawMesh(it.mesh, it.material, matrix(r));
            }
            if (transparent) c.rlEnableDepthMask();
        }
    }
};

/// triângulos soltos (normal por face: sombreamento chapado como na GUI)
fn upload(m: sk.Mesh) c.Mesh {
    var mesh = std.mem.zeroes(c.Mesh);
    const nv = m.f.len * 3;
    mesh.vertexCount = @intCast(nv);
    mesh.triangleCount = @intCast(m.f.len);
    const vb: [*]f32 = @ptrCast(@alignCast(c.MemAlloc(@intCast(nv * 3 * @sizeOf(f32)))));
    const nb: [*]f32 = @ptrCast(@alignCast(c.MemAlloc(@intCast(nv * 3 * @sizeOf(f32)))));
    for (m.f, 0..) |t, k| {
        const a = m.v[t[0]];
        const b = m.v[t[1]];
        const d = m.v[t[2]];
        const n = v3.unit(v3.cross(v3.sub(b, a), v3.sub(d, a)), .{ 0, 0, -1 });
        for ([_]V3{ a, b, d }, 0..) |p, j| {
            const i = (k * 3 + j) * 3;
            inline for (0..3) |q| {
                vb[i + q] = @floatCast(p[q]);
                nb[i + q] = @floatCast(n[q]);
            }
        }
    }
    mesh.vertices = vb;
    mesh.normals = nb;
    c.UploadMesh(&mesh, false);
    return mesh;
}

/// chão do hangar: a grade da GUI (6 m, de 25 em 25 cm, 30 cm abaixo do avião)
pub fn hangarGrid(below: f64) void {
    const col: c.Color = .{ .r = 0, .g = 0, .b = 0, .a = 40 };
    const h: f32 = @floatCast(-below);
    var i: i32 = -12;
    while (i <= 12) : (i += 1) {
        const x: f32 = @as(f32, @floatFromInt(i)) * 0.25;
        c.DrawLine3D(.{ .x = x, .y = h, .z = -3 }, .{ .x = x, .y = h, .z = 3 }, col);
        c.DrawLine3D(.{ .x = -3, .y = h, .z = x }, .{ .x = 3, .y = h, .z = x }, col);
    }
}
