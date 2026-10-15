"""Dimensões do avião medidas a partir do CG de projeto (como na planilha antiga: x_TDP, x_TDN, altura do CG,
braço da EH...). Fica mais simples dimensionar: tudo é "quanto à frente/atrás, ao lado, acima/abaixo do CG".

    rows = dimensions(ac)            # CG de projeto: ac.design_cg (a sprint grava) ou, sem ele, o CG atual
    rows = dimensions(ac, cg=(x, y, z))

Cada linha: (grupo, item, Δx, Δy, Δz, valor, nota)
    Δx, Δy, Δz   posição em relação ao CG, nos eixos do corpo: x + à frente, y + à direita, z + para baixo (m);
                 None quando não se aplica
    valor        a grandeza "de planilha", com o sinal que ela usa (ex.: x_TDP > 0 = trem atrás do CG)
O chão é o das rodas principais com o avião nivelado (triciclo).
"""
from __future__ import annotations

import math

Row = tuple  # (grupo, item, dx, dy, dz, valor, nota)


def design_cg(ac) -> tuple[float, float, float]:
    if ac.design_cg is not None and len(ac.design_cg) == 3:
        return tuple(float(v) for v in ac.design_cg)
    from aerosim.model.universal import build_model
    cg = build_model(ac).mass["cg"]
    return float(cg[0]), float(cg[1]), float(cg[2])


def _rel(p, cg):
    return p[0] - cg[0], p[1] - cg[1], p[2] - cg[2]


def _mac(w):
    from aerosim.design.wing import planform
    return planform(w)


def dimensions(ac, cg: tuple | None = None) -> list[Row]:
    cg = design_cg(ac) if cg is None else tuple(cg)
    rows: list[Row] = []
    add = lambda g, item, d=None, val=None, note="": rows.append((g, item, *(d or (None, None, None)), val, note))
    g = ac.gear
    legs = g.legs()
    ground = (g.main_z if g.layout != "custom" else max(l.z for l in legs)) if legs else None   # sem trem: sem chão
    h_cg = ground - cg[2] if ground is not None else None
    add("CG", "CG de projeto (x, y, z absolutos)", cg, None, "a origem das outras linhas")
    if ground is not None:
        add("CG", "altura do CG ao chão", None, h_cg, "z_CG (origem: chão)")
    hgt = lambda z: ground - z if ground is not None else None
    w = ac.wing
    if w is not None and w.sections:
        pf = _mac(w)
        x_le = pf["x_le_mac"]
        add("CG", "x_CG / CMA (do bordo de ataque da CMA)", None, (x_le - cg[0]) / pf["mac"], "adimensional")
        add("asa", "CA da asa (1/4 da CMA)", (pf["x_ac"] - cg[0], 0.0, w.z - cg[2]), (pf["x_ac"] - cg[0]) / pf["mac"],
            "valor: (x_CA − x_CG)/CMA; + = CA à frente do CG")
        add("asa", "bordo de ataque da raiz", _rel((w.x, w.y, w.z), cg), hgt(w.z), "valor: altura ao chão")
    if g.layout != "custom":
        add("trem", "TDP (trem principal)", (g.main_x - cg[0], g.main_track / 2, g.main_z - cg[2]), cg[0] - g.main_x,
            "x_TDP: do CG ao trem principal, + = atrás do CG")
        name = "TDN (bequilha)" if g.layout == "tricycle" else "roda de cauda"
        add("trem", name, (g.steer_x - cg[0], 0.0, g.steer_z - cg[2]),
            (g.steer_x - cg[0]) if g.layout == "tricycle" else (cg[0] - g.steer_x),
            "x_TDN: do CG à bequilha, + = à frente" if g.layout == "tricycle" else "do CG à roda de cauda, + = atrás")
        add("trem", "bitola", None, g.main_track, "entre as rodas principais")
        if h_cg is not None and h_cg > 0:
            add("trem", "ângulo de tombamento", None, math.degrees(math.atan2(cg[0] - g.main_x, h_cg)),
                "atan(x_TDP / altura do CG), °: ~15° é o usual")
        if g.layout == "tricycle" and g.tail_skid:
            add("trem", "sapata de cauda", (g.skid_x - cg[0], 0.0, g.skid_z - cg[2]), hgt(g.skid_z),
                "valor: altura ao chão")
    else:
        for k, l in enumerate(legs):
            add("trem", f"perna {k + 1} ({l.kind})", (l.x - cg[0], l.y - cg[1], l.z - cg[2]))
    for u in ac.propulsion:
        if not u.enabled:
            continue
        D = u.propeller.D
        add("motores", f"{u.name}: cubo da hélice", _rel((u.x, u.y, u.z), cg), hgt(u.z + D / 2),
            f"valor: folga da hélice ao chão (D = {D:.3f} m); inclinação {u.tilt:g}°")
    for s in ac.surfaces[1:]:
        if not s.enabled or not s.sections:
            continue
        pf = _mac(s)
        add("empenagem", f"{s.name}: CA", (pf["x_ac"] - cg[0], s.y - cg[1], s.z - cg[2]), cg[0] - pf["x_ac"],
            "valor: braço do CG ao CA (l_h, l_v), + = atrás do CG")
        if ground is not None:
            add("empenagem", f"{s.name}: altura ao chão", None, hgt(s.z), "da raiz")
    for k, b in enumerate(ac.booms):
        if b.enabled:
            add("tubos", f"{b.name}: ponta de trás", _rel(b.end, cg), cg[0] - b.end[0],
                f"valor: atrás do CG; inclinação {b.pitch:g}°")
    for t in ac.tanks:
        add("carga", f"{t.name}", _rel((t.x, t.y, t.z), cg), t.volume, "valor: litros")
    if ac.payload.enabled:
        p = ac.payload
        add("carga", "LAPES", _rel((p.x, p.y, p.z), cg), p.mass, "valor: kg")
    if ac.ballast.enabled:
        b = ac.ballast
        add("carga", "lastro", _rel((b.x, b.y, b.z), cg), b.mass, "valor: kg")
    for it in ac.mass.items:
        if "bateria" in it.name or "lastro" in it.name:
            add("massas", it.name, _rel((it.x, it.y, it.z), cg), it.mass, "valor: kg")
    return rows
