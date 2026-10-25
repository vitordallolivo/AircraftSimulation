"""Massa seca da aeronave: base (com inércia própria) + massas pontuais (Steiner).

O líquido dos tanques e a carga ficam fora: o núcleo soma em cada passo (eles se mexem).
"""
from __future__ import annotations

import numpy as np

from .aircraft import Aircraft


def point_items(ac: Aircraft) -> list[tuple[str, float, np.ndarray]]:
    mm = ac.mass
    out = [(it.name, it.mass, np.array([it.x, it.y, it.z])) for it in mm.items]
    b = getattr(ac, "ballast", None)
    if b is not None and b.enabled and b.mass > 0:
        out.append(("lastro", b.mass, np.array([b.x, b.y, b.z])))
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
                x = s.x - 0.4 * (s.mac or 0.2)
                r = _half_gyration(s) if s.symmetric and not s.vertical else None
                if r is None:
                    out.append((s.name, s.mass, np.array([x, s.y, s.z])))
                else:                   # cada meia asa com a metade da massa, no raio de giração dela (rolamento)
                    out.append((f"{s.name} (direita)", 0.5 * s.mass, np.array([x, r, s.z])))
                    out.append((f"{s.name} (esquerda)", 0.5 * s.mass, np.array([x, -r, s.z])))
        if ac.fuselage.enabled and ac.fuselage.mass > 0:
            f = ac.fuselage
            out.append(("fuselagem", f.mass, np.array([f.x_nose - 0.45 * f.length, 0, f.z])))
        for b in ac.booms:
            if b.enabled and b.mass > 0:
                out.append((b.name, b.mass, np.array(b.middle)))
    return out


def _half_gyration(s) -> float | None:
    """raio de giração da meia superfície em torno do plano de simetria, com a massa espalhada pela área (densidade
    por área constante): r² = ∫ (y_0 + η)² c(η) dη / ∫ c(η) dη, a corda linear entre as seções. É a definição do
    momento de inércia de uma placa fina (r² = I/m); None sem seções"""
    if len(s.sections) < 2:
        return None
    eta, c = [], []
    for a, b in zip(s.sections[:-1], s.sections[1:]):
        t = np.linspace(0.0, 1.0, 33)
        eta.append(a.y + t * (b.y - a.y))
        c.append(a.chord + t * (b.chord - a.chord))
    eta, c = np.concatenate(eta), np.concatenate(c)
    A = np.trapezoid(c, eta)
    if A <= 0:
        return None
    return float(np.sqrt(np.trapezoid((s.y + eta) ** 2 * c, eta) / A))


def dry_mass(ac: Aircraft) -> dict:
    """massa, CG e inércia no CG da aeronave seca"""
    mm = ac.mass
    m = mm.base_mass
    cg0 = np.array(mm.base_cg, float)
    I_base = np.array([[mm.Ixx, 0, -mm.Ixz], [0, mm.Iyy, 0], [-mm.Ixz, 0, mm.Izz]], float)
    items = point_items(ac)
    M = m + sum(it[1] for it in items)
    if M <= 0:                                       # avião vazio (Montagem começando do zero)
        return dict(m=0.0, cg=cg0, I=I_base, items=items)
    cg = (m * cg0 + sum(it[1] * it[2] for it in items)) / M
    def steiner(mk, r):
        d = r - cg
        return mk * (np.dot(d, d) * np.eye(3) - np.outer(d, d))
    I = I_base + steiner(m, cg0)
    for _, mk, r in items:
        I = I + steiner(mk, r)
    return dict(m=M, cg=cg, I=I, items=items)
