"""Tradutor da checagem de geometria: o modelo universal vira as peças simples do núcleo (`core/src/geometry`),
e o relatório do núcleo volta com os nomes das peças.

Cada peça é uma caixa orientada, um disco ou um ponto, no corpo (x à frente, y à direita, z para baixo):

    painel de asa ou de cauda    uma caixa por trecho entre estações, por lado: a corda e o trecho de envergadura,
                                 com a espessura do perfil e o que a torção desce o bordo de fuga
    fuselagem                    quatro caixas ao longo do comprimento, com o perfil da vista 3D (nariz arredondado,
                                 cauda afinando), não a caixa inteira, que bateria no chão antes da fuselagem de verdade
    tubo de cauda                uma caixa do começo ao fim, com o diâmetro
    motor                        a caixa do corpo do motor como a vista 3D desenha (12 cm atrás da hélice na tratora,
                                 à frente na propulsora) e o disco da hélice, do mesmo dono
    massas                       um ponto por massa concentrada (itens do modelo de massa, carga, lastro, tanques)

O trem de pouso não entra: é ele que define o chão (o pivô sob o trem principal e a atitude parada, pela bequilha
ou pela roda de cauda).
"""
from __future__ import annotations

import ctypes
import math

import numpy as np

from aerosim.interfaces.geometry import GeometryParams, GeometryReport, IGeometryCheck

from . import abi

X = np.array([1.0, 0.0, 0.0])


def _unit(a):
    n = float(np.linalg.norm(a))
    return a / n if n > 1e-12 else None


def _obb(points, e1, e2, extra=(0.0, 0.0, 0.0)) -> dict:
    """a caixa orientada (e1, e2, e1 × e2) que cobre os pontos, mais `extra` de meia medida em cada eixo"""
    e3 = np.cross(e1, e2)
    P = np.asarray(points, float)
    ax = np.vstack([e1, e2, e3])
    q = P @ ax.T
    lo, hi = q.min(axis=0), q.max(axis=0)
    mid = 0.5 * (lo + hi)
    return dict(kind=0, c=list(mid @ ax), ax=list(ax.ravel()), h=list(0.5 * (hi - lo) + np.asarray(extra)))


def _segment(p0, p1, r: float) -> dict | None:
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    e = _unit(p1 - p0)
    if e is None:
        return None
    t = _unit(np.cross(e, [0, 0, 1.0]) if abs(e[2]) < 0.9 else np.cross(e, [0, 1.0, 0]))
    return _obb([p0, p1], e, t, (0.0, r, r))


def _thickness(af) -> float:
    try:
        o = af.outline()
        return float(o[:, 1].max() - o[:, 1].min())
    except Exception:  # noqa: BLE001 — perfil sem contorno: a espessura típica
        return 0.12


def _surface_boxes(s) -> list[dict]:
    out = []
    tc = _thickness(s.airfoil)
    for sy in ((1, -1) if s.mirror else (1,)):
        mir = np.array([1.0, sy, 1.0])
        for a, b in zip(s.stations[:-1], s.stations[1:]):
            la, lb = a.le * mir, b.le * mir
            sd = _unit(lb - la)
            if sd is None:
                continue
            e1 = _unit(X - X.dot(sd) * sd)
            if e1 is None:
                continue
            pts = [la, la - a.chord * X, lb, lb - b.chord * X]
            c = max(a.chord, b.chord)
            drop = max(abs(math.sin(math.radians(q.twist))) * q.chord for q in (a, b)) if not s.vertical else 0.0
            out.append(_obb(pts, e1, sd, (0.0, 0.0, 0.5 * tc * c + 0.5 * drop)))
    return out


def _fuselage_boxes(f, n: int = 4) -> list[dict]:
    def prof(t):         # o mesmo perfil de `model.geometry.ellipsoid_body`
        p = math.sin(math.pi * min(t / 0.3, 1.0) / 2) if t < 0.3 else 1.0 - 0.75 * ((t - 0.3) / 0.7) ** 1.5
        return max(p, 0.02)
    out = []
    for k in range(n):
        t0, t1 = k / n, (k + 1) / n
        p = max(prof(t) for t in np.linspace(t0, t1, 9))
        xc = f.x_nose - 0.5 * (t0 + t1) * f.length
        out.append(dict(kind=0, c=[xc, 0.0, f.z], ax=[1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0],
                        h=[0.5 * (t1 - t0) * f.length, 0.5 * f.width * p, 0.5 * f.height * p]))
    return out


def _attitude(gear) -> tuple[np.ndarray, float]:
    """o pivô no chão sob o trem principal e a atitude parada (rad, + nariz para cima)"""
    legs = gear.legs()
    mains = [g for g in legs if g.kind == "main"] or legs
    if not mains:
        return np.zeros(3), 0.0
    pivot = np.array([np.mean([g.x for g in mains]), 0.0, np.mean([g.z for g in mains])])
    other = [g for g in legs if g.kind == "steer"]
    if not other:
        return pivot, 0.0
    g = other[0]
    dx, dz = g.x - pivot[0], g.z - pivot[2]
    return pivot, (math.atan(dz / dx) if abs(dx) > 1e-9 else 0.0)


def scene(model, params: GeometryParams | None = None) -> tuple[dict, list[str]]:
    """a cena do núcleo (dicionário da struct Scene) e o nome de cada peça"""
    gp = params or GeometryParams()
    ac = model.aircraft
    parts, names = [], []
    owner = 0

    def add(p, name, own):
        if p is not None:
            parts.append(dict(p, owner=own))
            names.append(name)
    for s in model.surfaces:
        owner += 1
        for p in _surface_boxes(s):
            add(p, s.name, owner)
    f = ac.fuselage
    if f.enabled:
        owner += 1
        for p in _fuselage_boxes(f):
            add(p, "fuselagem", owner)
    for b in ac.booms:
        if b.enabled:
            owner += 1
            add(_segment(b.start, b.end, b.diameter / 2), b.name, owner)
    for u in ac.propulsion:
        if not u.enabled:
            continue
        owner += 1
        t, q = math.radians(u.tilt), math.radians(u.toe)
        e = np.array([math.cos(t) * math.cos(q), math.cos(t) * math.sin(q), -math.sin(t)])
        p = np.array([u.x, u.y, u.z])
        k = 1.0 if u.x < 0 else -1.0             # propulsora: motor à frente da hélice; tratora: atrás
        add(_segment(p, p + k * 0.12 * e, 0.035), f"{u.name}: motor", owner)
        add(dict(kind=1, c=list(p), ax=list(e) + [0.0] * 6, h=[u.propeller.D / 2, 0.0, 0.0]), f"{u.name}: hélice", owner)
    if gp.masses:
        pts = [(m.name, (m.x, m.y, m.z)) for m in ac.mass.items]
        if ac.payload.enabled:
            pts.append(("carga paga", (ac.payload.x, ac.payload.y, ac.payload.z)))
        if ac.ballast.enabled:
            pts.append(("lastro", (ac.ballast.x, ac.ballast.y, ac.ballast.z)))
        pts += [(t.name, (t.x, t.y, t.z)) for t in ac.tanks]
        for name, c in pts:
            owner += 1
            add(dict(kind=2, c=list(map(float, c))), name, owner)
    pivot, th0 = _attitude(ac.gear)
    rot = max(th0, math.radians(gp.rotation))
    return dict(n=len(parts), parts=parts, pivot=list(pivot), n_att=2, att=[th0, rot], clearance=gp.clearance,
                prop_clearance=gp.prop_clearance, contact_tol=gp.contact_tol, hub=gp.hub,
                need_connected=int(gp.connected)), names


def report(r: dict, names: list[str], att: list[float], need: bool = True) -> GeometryReport:
    """o relatório do núcleo com os nomes das peças e os motivos em português"""
    out = GeometryReport(ok=bool(r["ok"]), gear_raise=float(r["gear_raise"]))
    for a, b in zip(r["hit_a"][:r["n_hits"]], r["hit_b"][:r["n_hits"]]):
        out.prop_hits.append((names[a], names[b]))
    out.outside = [names[i] for i in r["outside"][:r["n_outside"]]]
    groups: dict[int, list[str]] = {}
    for i, g in enumerate(r["group"][:len(names)]):
        if g >= 0 and names[i] not in groups.setdefault(g, []):
            groups[g].append(names[i])
    out.groups = [groups[k] for k in sorted(groups)]
    for k, label in enumerate(("parado", "na rotação")):
        i = r["low_part"][k]
        out.ground.append((f"{label} ({math.degrees(att[k]):.1f}°)", float(r["low"][k]), names[i] if i >= 0 else ""))
    if out.prop_hits:
        out.reasons.append("hélice acerta " + ", ".join(f"{a} × {b}" for a, b in out.prop_hits))
    if out.outside:
        out.reasons.append("fora da geometria: " + ", ".join(out.outside))
    if len(out.groups) > 1 and need:
        out.reasons.append("peças soltas, sem nada que as ligue: " + " | ".join(", ".join(g) for g in out.groups[1:]))
    for label, low, part in out.ground:
        if low < 0:
            out.reasons.append(f"{part} bate no chão {label} ({low * 100:.1f} cm)")
    return out


class ZigGeometry(IGeometryCheck):
    name = "núcleo (caixas, discos e pontos)"

    def __init__(self, lib=None):
        if lib is None:
            from .backend import _Lib
            lib = _Lib.get(None)
        self._lib = lib

    def check(self, model, params: GeometryParams | None = None) -> GeometryReport:
        return self.check_many([model], params)[0]

    def check_many(self, models, params: GeometryParams | None = None) -> list[GeometryReport]:
        T = self._lib.schema.types
        models = list(models)
        if not models:
            return []
        scenes = (T["Scene"] * len(models))()
        reports = (T["Report"] * len(models))()
        meta = []
        for i, m in enumerate(models):
            spec, names = scene(m, params)
            abi.write(scenes[i], spec)
            meta.append((names, spec["att"], bool(spec["need_connected"])))
        self._lib.dll.aerosim_geometry_check(ctypes.addressof(scenes), len(models), ctypes.addressof(reports))
        return [report(abi.read(reports[i]), *meta[i]) for i in range(len(models))]
