"""Massa seca da aeronave: base (com inércia própria) + massas pontuais (Steiner).

O líquido dos tanques e a carga ficam fora: o núcleo soma em cada passo (eles se mexem).
"""
from __future__ import annotations

import numpy as np

from .aircraft import Aircraft


def point_items(ac: Aircraft) -> list[tuple[str, float, np.ndarray]]:
    mm = ac.mass
    out = [(it.name, it.mass, np.array([it.x, it.y, it.z])) for it in mm.items]
    if mm.include_propulsion:
        for u in ac.propulsion:
            if u.enabled:
                p = np.array([u.x, u.y, u.z])
                k = 1.0 if u.x < 0 else -1.0       # propulsora: motor à frente da hélice
                out.append((f"{u.name}: motor", u.motor.mass, p + [k * 0.06, 0, 0]))
                out.append((f"{u.name}: hélice", u.propeller.mass, p))
                out.append((f"{u.name}: bateria", u.battery.mass, p + [k * 0.25, 0, 0]))
    if mm.include_structure:
        for s in ac.surfaces:
            if s.enabled and s.mass > 0:
                out.append((s.name, s.mass, np.array([s.x - 0.4 * (s.mac or 0.2), s.y, s.z])))
        if ac.fuselage.enabled and ac.fuselage.mass > 0:
            f = ac.fuselage
            out.append(("fuselagem", f.mass, np.array([f.x_nose - 0.45 * f.length, 0, f.z])))
        if ac.boom.enabled and ac.boom.mass > 0:
            b = ac.boom
            out.append(("tubo de cauda", b.mass, np.array([0.5 * (b.x_start + b.x_end), 0, b.z])))
    return out


def dry_mass(ac: Aircraft) -> dict:
    """massa, CG e inércia no CG da aeronave seca"""
    mm = ac.mass
    m = mm.base_mass
    cg0 = np.array(mm.base_cg, float)
    I_base = np.array([[mm.Ixx, 0, -mm.Ixz], [0, mm.Iyy, 0], [-mm.Ixz, 0, mm.Izz]], float)
    items = point_items(ac)
    M = m + sum(it[1] for it in items)
    cg = (m * cg0 + sum(it[1] * it[2] for it in items)) / M
    def steiner(mk, r):
        d = r - cg
        return mk * (np.dot(d, d) * np.eye(3) - np.outer(d, d))
    I = I_base + steiner(m, cg0)
    for _, mk, r in items:
        I = I + steiner(mk, r)
    return dict(m=M, cg=cg, I=I, items=items)
