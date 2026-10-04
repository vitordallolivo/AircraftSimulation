"""Malhas 3D para a GUI (a partir do modelo universal) e posição/arraste dos componentes na
configuração. Os painéis do núcleo NÃO são feitos aqui: o modelo universal
(`aerosim.model.universal`) é traduzido pelo tradutor de cada núcleo/solver.
"""
from __future__ import annotations

import math

import numpy as np

from .aircraft import Aircraft
from .universal import SurfaceModel, build_model

Mesh = tuple[np.ndarray, np.ndarray]     # vértices (N, 3) no corpo, faces (M, 3)


def _loft(rings: list[np.ndarray], cap: bool = True) -> Mesh:
    n = len(rings[0])
    V = np.vstack(rings)
    F = []
    for k in range(len(rings) - 1):
        a, b = k * n, (k + 1) * n
        for i in range(n):
            j = (i + 1) % n
            F += [[a + i, b + i, b + j], [a + i, b + j, a + j]]
    if cap:
        for base in (0, (len(rings) - 1) * n):
            for i in range(1, n - 1):
                F.append([base, base + i, base + i + 1])
    return V, np.array(F, dtype=np.int32)


def _frame(s: SurfaceModel) -> np.ndarray:
    """direção da espessura (perpendicular à envergadura, no plano y-z)"""
    if s.vertical:
        return np.array([0.0, 1.0, 0.0])
    d = s.tip.le - s.stations[0].le
    u = np.array([0.0, d[1], d[2]])
    u /= max(np.linalg.norm(u), 1e-12)
    return np.array([0.0, u[2], -u[1]])


def _sides(s: SurfaceModel):
    return (1, -1) if s.mirror else (1,)


def surface_mesh(s: SurfaceModel) -> list[Mesh]:
    """uma malha por lado; perfil do .dat ou NACA, torção em torno do bordo de ataque"""
    def shape(a):
        af = a.outline()
        return af[np.linspace(0, len(af) - 1, 80).astype(int)] if len(af) > 80 else af
    n = _frame(s)

    def ring(q, af, mir):
        tw = math.radians(q.twist) if not s.vertical else 0.0
        xs, th = -af[:, 0] * q.chord, af[:, 1] * q.chord
        xr = xs * math.cos(tw) - th * math.sin(tw)
        tr = xs * math.sin(tw) + th * math.cos(tw)
        return (q.le[None, :] + np.outer(xr, [1.0, 0.0, 0.0]) + np.outer(tr, n)) * mir
    meshes = []
    for sy in _sides(s):
        mir = np.array([1.0, sy, 1.0])
        if s.strip_airfoils:                         # perfil por seção: cada faixa com o perfil dela
            for (a, b, _), af in zip(s.strips(), s.strip_airfoils):
                p = shape(af)
                meshes.append(_loft([ring(a, p, mir), ring(b, p, mir)]))
            continue
        af = shape(s.airfoil)
        meshes.append(_loft([ring(q, af, mir) for q in s.stations]))
    return meshes


def control_meshes(s: SurfaceModel) -> list[Mesh]:
    """placas finas sobre a parte móvel (destaque visual dos comandos)"""
    out = []
    n = _frame(s) * 0.004
    for a, b, ctl in s.strips():
        if ctl is None:
            continue
        for sy in _sides(s):
            mir = np.array([1.0, sy, 1.0])
            quad = []
            for q in (a, b):
                xte = q.le[0] - q.chord
                for xx in (xte + ctl.chord_frac * q.chord, xte):
                    quad.append(np.array([xx, q.le[1], q.le[2]]) * mir)
            Q = np.array(quad)
            V = np.vstack([Q + n * mir, Q - n * mir])
            F = np.array([[0, 1, 3], [0, 3, 2], [4, 7, 5], [4, 6, 7]], dtype=np.int32)
            out.append((V, F))
    return out


def ellipsoid_body(x_nose: float, length: float, width: float, height: float, z: float = 0.0,
                   n_len: int = 24, n_ring: int = 20) -> Mesh:
    rings = []
    for i in range(n_len + 1):
        f = i / n_len
        # nariz arredondado, cauda afinando
        prof = math.sin(math.pi * min(f / 0.3, 1.0) / 2) if f < 0.3 else 1.0 - 0.75 * ((f - 0.3) / 0.7) ** 1.5
        prof = max(prof, 0.02)
        x = x_nose - f * length
        a = np.linspace(0, 2 * math.pi, n_ring, endpoint=False)
        rings.append(np.column_stack([np.full(n_ring, x), 0.5 * width * prof * np.cos(a),
                                      z + 0.5 * height * prof * np.sin(a)]))
    return _loft(rings)


def cylinder(p0, p1, radius: float, n: int = 16) -> Mesh:
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    ax = p1 - p0
    L = np.linalg.norm(ax)
    ax = ax / L if L > 1e-9 else np.array([0.0, 0.0, 1.0])
    t = np.cross(ax, [0, 0, 1.0]) if abs(ax[2]) < 0.9 else np.cross(ax, [0, 1.0, 0])
    t /= np.linalg.norm(t)
    u = np.cross(ax, t)
    a = np.linspace(0, 2 * math.pi, n, endpoint=False)
    ring = radius * (np.outer(np.cos(a), t) + np.outer(np.sin(a), u))
    return _loft([p0 + ring, p1 + ring])


def box(center, size) -> Mesh:
    c = np.asarray(center, float)
    s = np.asarray(size, float) / 2
    V = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]) * s + c
    F = np.array([[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5], [0, 4, 5], [0, 5, 1],
                  [2, 3, 7], [2, 7, 6], [0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]], dtype=np.int32)
    return V, F


def thrust_axis(u) -> np.ndarray:
    t, p = math.radians(u.tilt), math.radians(u.toe)
    return np.array([math.cos(t) * math.cos(p), math.cos(t) * math.sin(p), -math.sin(t)])


def aircraft_meshes(ac: Aircraft) -> dict[str, list[tuple[Mesh, str]]]:
    """componente -> [(malha, tipo de cor)]. A chave é o identificador usado na GUI
    para escolher/arrastar ('surface:0', 'prop:1', 'tank:0', 'payload', 'gear', ...)."""
    out: dict[str, list] = {}
    for s in build_model(ac).surfaces:      # o mesmo modelo universal que os solvers recebem
        key = f"surface:{s.index}"
        out.setdefault(key, [])
        out[key] += [(m, s.role) for m in surface_mesh(s)] + [(m, "control") for m in control_meshes(s)]
    f = ac.fuselage
    if f.enabled:
        out["fuselage"] = [(ellipsoid_body(f.x_nose, f.length, f.width, f.height, f.z), "fuselage")]
    for i, b in enumerate(ac.booms):
        if b.enabled:
            out[f"boom:{i}"] = [(cylinder(list(b.start), list(b.end), b.diameter / 2), "boom")]
    for i, u in enumerate(ac.propulsion):
        if not u.enabled:
            continue
        e = thrust_axis(u)
        p = np.array([u.x, u.y, u.z])
        D = u.propeller.D
        k = 1.0 if u.x < 0 else -1.0          # propulsora: motor à frente da hélice; tratora: atrás
        out[f"prop:{i}"] = [(cylinder(p + k * 0.12 * e, p + k * 0.01 * e, 0.035), "motor"),
                            (cylinder(p, p + 0.004 * e, D / 2, 32), "propdisk")]
    for i, t in enumerate(ac.tanks):
        out[f"tank:{i}"] = [(box([t.x, t.y, t.z], [t.side, t.side, max(t.height, t.fill)]), "tank"),
                            (box([t.x, t.y, t.z + t.height / 2 - t.fill / 2], [t.side * 0.96, t.side * 0.96, t.fill]),
                             "liquid")]
    if ac.payload.enabled:
        P = ac.payload
        out["payload"] = [(box([P.x, P.y, P.z], [0.18, 0.12, 0.08]), "payload")]
    b = ac.ballast
    if b.enabled:
        sz = max(0.03, min(0.12, (b.mass / 7800.0) ** (1 / 3) * 1.6))     # cubo de aço com a massa do lastro
        out["ballast"] = [(box([b.x, b.y, b.z], [sz, sz, sz]), "ballast")]
    legs = []
    for g in ac.gear.legs():
        legs.append((box([g.x, g.y, g.z], [0.06, 0.025, 0.06]), "wheel"))
        legs.append((cylinder([g.x, g.y, 0.0], [g.x, g.y, g.z], 0.006, 8), "strut"))
    out["gear"] = legs
    return out


def component_position(ac: Aircraft, key: str) -> np.ndarray | None:
    kind, _, idx = key.partition(":")
    if kind == "surface":
        s = ac.surfaces[int(idx)]
        return np.array([s.x, s.y, s.z])
    if kind == "prop":
        u = ac.propulsion[int(idx)]
        return np.array([u.x, u.y, u.z])
    if kind == "tank":
        t = ac.tanks[int(idx)]
        return np.array([t.x, t.y, t.z])
    if kind == "payload":
        return np.array([ac.payload.x, ac.payload.y, ac.payload.z])
    if kind == "ballast":
        return np.array([ac.ballast.x, ac.ballast.y, ac.ballast.z])
    if kind == "fuselage":
        return np.array([ac.fuselage.x_nose, 0, ac.fuselage.z])
    if kind == "boom":
        return np.array(ac.booms[int(idx)].start)
    if kind == "gear":
        return np.array([ac.gear.main_x, 0, ac.gear.main_z])
    return None


def move_component(ac: Aircraft, key: str, pos) -> None:
    """põe o componente na posição (corpo); usado pelo arraste com o mouse"""
    x, y, z = (float(v) for v in pos)
    kind, _, idx = key.partition(":")
    if kind == "surface":
        s = ac.surfaces[int(idx)]
        s.x, s.y, s.z = x, (y if not s.symmetric or s.vertical else 0.0), z
    elif kind == "prop":
        u = ac.propulsion[int(idx)]
        u.x, u.y, u.z = x, y, z
    elif kind == "tank":
        t = ac.tanks[int(idx)]
        t.x, t.y, t.z = x, y, z
    elif kind == "payload":
        ac.payload.x, ac.payload.y, ac.payload.z = x, y, z
    elif kind == "ballast":
        ac.ballast.x, ac.ballast.y, ac.ballast.z = x, y, z
    elif kind == "fuselage":
        ac.fuselage.x_nose, ac.fuselage.z = x, z
    elif kind == "boom":
        b = ac.booms[int(idx)]
        b.x_start, b.y, b.z = x, y, z
    elif kind == "gear":
        ac.gear.main_x, ac.gear.main_z = x, max(z, 0.01)
    ac.apply_constraints()
