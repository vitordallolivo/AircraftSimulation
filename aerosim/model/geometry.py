"""Geometria: superfícies -> painéis do núcleo, e malhas 3D para a GUI.

Painéis: cada superfície é cortada em faixas nas seções e nas bordas dos comandos
(aileron, profundor, elevon...). Cada faixa de cada lado vira um painel com centro
aerodinâmico a 25 % da corda média da faixa, já com enflechamento e diedro.
"""
from __future__ import annotations

import math

import numpy as np

from .aircraft import Aircraft, ControlSurface, LiftingSurface
from .airfoil import flap_effectiveness, helmbold

GROUP = {"wing": 0, "htail": 1, "vtail": 2}


def _breaks(s: LiftingSurface) -> list[float]:
    """posições ao longo da envergadura onde a superfície é cortada (seções e bordas de comandos)"""
    b = s.semispan
    ys = [sec.y for sec in s.sections]
    for c in s.controls:
        ys += [min(max(c.span_start, 0.0), 1.0) * b, min(max(c.span_end, 0.0), 1.0) * b]
    out: list[float] = []
    for y in sorted(min(max(y, 0.0), b) for y in ys):
        if not out or y - out[-1] > 1e-9:
            out.append(y)
    return out


def control_at(s: LiftingSurface, y: float) -> ControlSurface | None:
    b = s.semispan
    for c in s.controls:
        if c.span_start * b - 1e-9 <= y <= c.span_end * b + 1e-9:
            return c
    return None


def _mix(kind: str, side: int, vertical: bool) -> list[float]:
    if kind == "elevator":
        return [1.0, 0.0, 0.0]
    if kind == "aileron":
        return [0.0, -float(side), 0.0]
    if kind == "elevon":
        return [1.0, -float(side), 0.0]
    if kind == "rudder":
        return [0.0, 0.0, -1.0]
    if kind == "ruddervator":
        return [1.0, 0.0, -float(side)]
    return [0.0, 0.0, 0.0]          # flape: deflexão fixa


def aero_coefficients(s: LiftingSurface) -> dict[str, float]:
    AR = s.aspect_ratio or 5.0
    CLa = s.CLa if s.CLa is not None else helmbold(s.airfoil.cl_alpha, AR)
    CL0 = s.CL0 if s.CL0 is not None else -CLa * math.radians(s.airfoil.zero_lift_angle())
    return dict(AR=AR, CLa=CLa, CL0=CL0,
                CLmax=s.CLmax if s.CLmax is not None else 0.9 * s.airfoil.cl_max,
                CD0=s.CD0 if s.CD0 is not None else s.airfoil.cd0,
                Cmac=s.Cmac if s.Cmac is not None else s.airfoil.moment_ac())


def surface_panels(s: LiftingSurface, downwash: tuple[float, float] = (0.0, 0.0)) -> list[dict]:
    """painéis (dicionários no formato do núcleo, SI/rad)"""
    if not s.enabled or len(s.sections) < 2:
        return []
    co = aero_coefficients(s)
    ys = _breaks(s)
    dih = math.radians(s.dihedral)
    sides = (0,) if (s.vertical or not s.symmetric) else (1, -1)
    out = []
    for y0, y1 in zip(ys, ys[1:]):
        if y1 - y0 < 1e-6:
            continue
        ym = 0.5 * (y0 + y1)
        c0, c1 = s.chord_at(y0), s.chord_at(y1)
        S = 0.5 * (c0 + c1) * (y1 - y0)
        cm = S / (y1 - y0)
        xac = s.x - s.xoff_at(ym) - 0.25 * cm
        ctl = control_at(s, ym)
        tau = 0.0
        inc = s.incidence + s.twist_at(ym)
        if ctl is not None:
            tau = ctl.tau if ctl.tau is not None else flap_effectiveness(ctl.chord_frac)
            if ctl.kind == "flap":
                inc += tau * ctl.deflection
        e0 = math.radians(s.eps0) if s.eps0 is not None else downwash[0]
        ed = s.depsda if s.depsda is not None else downwash[1]
        for side in sides:
            if s.vertical:
                r = [xac, s.y, s.z - ym]
            else:
                sd = side if side else 1
                r = [xac, s.y + sd * ym * math.cos(dih), s.z - ym * math.sin(dih)]
            mix = _mix(ctl.kind, side, s.vertical) if ctl is not None else [0.0, 0.0, 0.0]
            out.append(dict(
                r=r, S=S, c=cm, AR=co["AR"], e=s.oswald, dihedral=dih, incidence=math.radians(inc),
                CLa=co["CLa"], CL0=co["CL0"], CLmax=co["CLmax"], CD0=co["CD0"], Cmac=co["Cmac"],
                tau=tau if ctl is not None and ctl.kind != "flap" else 0.0, mix=mix, eta=s.eta,
                eps0=e0 if s.downwash else 0.0, depsda=ed if s.downwash else 0.0,
                group=GROUP.get(s.role, 0), vertical=int(s.vertical), side=side, downwash=int(s.downwash),
            ))
    return out


def wing_downwash(ac: Aircraft) -> tuple[float, float]:
    """ε = ε0 + dε/dα α  da asa principal (rad)"""
    w = ac.wing
    if w is None:
        return 0.0, 0.0
    co = aero_coefficients(w)
    CLw0 = co["CL0"] + co["CLa"] * math.radians(w.incidence)
    return 2 * CLw0 / (math.pi * co["AR"]), 2 * co["CLa"] / (math.pi * co["AR"])


def all_panels(ac: Aircraft) -> list[dict]:
    dw = wing_downwash(ac)
    out = []
    for s in ac.surfaces:
        out += surface_panels(s, dw)
    return out


# ================================================================== malhas 3D
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


def surface_mesh(s: LiftingSurface, n_span: int = 2) -> list[Mesh]:
    """uma malha por lado (meia asa); perfil do .dat ou NACA"""
    if not s.enabled or len(s.sections) < 2:
        return []
    af = s.airfoil.outline()
    if len(af) > 80:
        af = af[np.linspace(0, len(af) - 1, 80).astype(int)]
    dih = math.radians(s.dihedral)
    ys = sorted({sec.y for sec in s.sections} | set(_breaks(s)))
    sides = (0,) if (s.vertical or not s.symmetric) else (1, -1)
    meshes = []
    for side in sides:
        rings = []
        for y in ys:
            c = s.chord_at(y)
            tw = math.radians(s.incidence + s.twist_at(y))
            xle = s.x - s.xoff_at(y)
            xs = -af[:, 0] * c
            th = af[:, 1] * c
            # torção/incidência em torno do bordo de ataque
            xr = xs * math.cos(tw) - th * math.sin(tw)
            tr = xs * math.sin(tw) + th * math.cos(tw)
            if s.vertical:
                P = np.column_stack([xle + xr, s.y + tr, np.full_like(xr, s.z - y)])
            else:
                sd = side if side else 1
                yy = s.y + sd * (y * math.cos(dih)) + 0 * tr
                zz = s.z - y * math.sin(dih) - tr
                P = np.column_stack([xle + xr, np.full_like(xr, 0) + yy, zz])
            rings.append(P)
        meshes.append(_loft(rings))
    return meshes


def control_meshes(s: LiftingSurface) -> list[Mesh]:
    """placas finas sobre a parte móvel (destaque visual dos comandos)"""
    out = []
    if not s.enabled:
        return out
    dih = math.radians(s.dihedral)
    sides = (0,) if (s.vertical or not s.symmetric) else (1, -1)
    b = s.semispan
    for ctl in s.controls:
        y0, y1 = ctl.span_start * b, ctl.span_end * b
        for side in sides:
            quad = []
            for y in (y0, y1):
                c = s.chord_at(y)
                xte = s.x - s.xoff_at(y) - c
                for xx in (xte + ctl.chord_frac * c, xte):
                    if s.vertical:
                        quad.append([xx, s.y, s.z - y])
                    else:
                        sd = side if side else 1
                        quad.append([xx, s.y + sd * y * math.cos(dih), s.z - y * math.sin(dih)])
            q = np.array(quad)
            off = np.array([0, 0.004, 0]) if s.vertical else np.array([0, 0, -0.004])
            V = np.vstack([q + off, q - off])
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
    for i, s in enumerate(ac.surfaces):
        if not s.enabled:
            continue
        out[f"surface:{i}"] = [(m, s.role) for m in surface_mesh(s)] + [(m, "control") for m in control_meshes(s)]
    f = ac.fuselage
    if f.enabled:
        out["fuselage"] = [(ellipsoid_body(f.x_nose, f.length, f.width, f.height, f.z), "fuselage")]
    if ac.boom.enabled:
        b = ac.boom
        out["boom"] = [(cylinder([b.x_start, 0, b.z], [b.x_end, 0, b.z], b.diameter / 2), "boom")]
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
        out[f"tank:{i}"] = [(box([t.x, t.y, t.z], [t.side, t.side, t.height]), "tank"),
                            (box([t.x, t.y, t.z + t.height / 2 - t.fill / 2], [t.side * 0.96, t.side * 0.96, t.fill]),
                             "liquid")]
    if ac.payload.enabled:
        P = ac.payload
        out["payload"] = [(box([P.x, P.y, P.z], [0.18, 0.12, 0.08]), "payload")]
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
    if kind == "fuselage":
        return np.array([ac.fuselage.x_nose, 0, ac.fuselage.z])
    if kind == "boom":
        return np.array([ac.boom.x_start, 0, ac.boom.z])
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
    elif kind == "fuselage":
        ac.fuselage.x_nose, ac.fuselage.z = x, z
    elif kind == "boom":
        ac.boom.x_start, ac.boom.z = x, z
    elif kind == "gear":
        ac.gear.main_x, ac.gear.main_z = x, max(z, 0.01)
    ac.apply_constraints()
