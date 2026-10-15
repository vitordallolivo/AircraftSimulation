"""CG do avião com a carga que a Montagem definiu, e acertar o CG de projeto.

A sprint põe a LAPES e os tanques no CG de projeto, sem kg; na Montagem se decide quanto pesa cada coisa e
onde fica. Tudo entra na simulação (o núcleo soma LAPES e líquido na posição deles: massa, CG e inércia; a
LAPES sai na soltura; o líquido balança — sloshing). Este módulo diz o que isso faz com o CG:

    full_cg(ac)           (massa, CG) com a carga — o mesmo do núcleo (`mass_props`)
    cg_after_drop(ac)     (massa, CG) depois da soltura da LAPES
    rebalance(ac)         move a bateria (ou o lastro ligado) para o CG voltar ao de projeto

Como o ponto neutro não depende do CG, a margem estática muda o mesmo tanto que o CG anda, em % da CMA
(para a frente: + margem).
"""
from __future__ import annotations

import numpy as np


def _liquid(ac):
    return [(t.volume * t.rho / 1000.0, np.array([t.x, t.y, t.z])) for t in ac.tanks if t.volume > 0]


def full_cg(ac, with_payload: bool = True) -> tuple[float, np.ndarray]:
    from aerosim.model.universal import build_model
    mm = build_model(ac).mass
    m = float(mm["m"])
    s = np.asarray(mm["cg"], float) * m
    parts = _liquid(ac)
    if with_payload and ac.payload.enabled and ac.payload.mass > 0:
        p = ac.payload
        parts.append((p.mass, np.array([p.x, p.y, p.z])))
    for mi, ri in parts:
        m += mi
        s = s + mi * ri
    return m, s / m if m > 0 else s


def cg_after_drop(ac) -> tuple[float, np.ndarray]:
    return full_cg(ac, with_payload=False)


def mac(ac) -> float:
    w = ac.wing
    if w is None or not w.sections:
        return float("nan")
    from .wing import planform
    return planform(w)["mac"]


def _battery(ac):
    """o item que dá para mover: a bateria da sprint (massa pontual) ou, sem ela, o lastro ligado"""
    it = next((i for i in ac.mass.items if "bateria" in i.name.lower()), None)
    if it is not None:
        return "bateria", it
    if ac.ballast.enabled and ac.ballast.mass > 0:
        return "lastro", ac.ballast
    return None, None


def rebalance(ac, target: float | None = None) -> tuple[bool, str]:
    """move a bateria (ou o lastro) em x para o CG (com a carga) voltar ao x de projeto. Dentro da fuselagem,
    se ela existir; se não alcançar, diz quanto faltou. Muda o avião no lugar."""
    if target is None:
        if ac.design_cg is None:
            return False, "o avião não tem CG de projeto (não veio da sprint): nada a acertar"
        target = float(ac.design_cg[0])
    what, it = _battery(ac)
    if it is None:
        return False, "não há bateria (massa pontual) nem lastro ligado para mover"
    m, cg = full_cg(ac)
    if abs(cg[0] - target) < 1e-6:
        return True, "o CG já está no de projeto"
    x_new = it.x + (target - cg[0]) * m / it.mass
    f = ac.fuselage
    lo, hi = (f.x_nose - f.length + 0.05, f.x_nose - 0.05) if f.enabled else (-np.inf, np.inf)
    x_ok = float(min(max(x_new, lo), hi))
    old = it.x
    it.x = x_ok
    m, cg = full_cg(ac)
    c = mac(ac)
    miss = (cg[0] - target) / c * 100 if c == c else float("nan")
    if abs(x_ok - x_new) > 1e-9:
        return False, (f"{what}: x {old:+.3f} → {x_ok:+.3f} m (no limite da fuselagem); o CG ainda fica "
                       f"{miss:+.1f} % CMA do de projeto — mude a posição da carga ou use lastro")
    return True, f"{what}: x {old:+.3f} → {x_ok:+.3f} m; o CG voltou ao de projeto"
