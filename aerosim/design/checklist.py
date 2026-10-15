"""Lista de verificação do avião antes de salvar: o que falta definir e o que o projeto pede.

Três grupos, cada item um `Check` (ok / atenção / falha / info):

    "definir"      o que o avião ainda não tem: massa da LAPES, líquido dos tanques, lastro ligado sem massa,
                   motor, asa, decolagem ajustada (profundor)
    "requisitos"   as condições de partida do projeto que dá para conferir no avião (massa estimada)
    "restrições"   as restrições ativas do projeto (Condições e restrições…) que o avião responde sozinho:
                   envergadura, área, alongamento, corda, comprimento, número de superfícies e de motores,
                   potência, massas de carga, massa, PV, CP, EE. As que precisam de uma análise
                   (corrida, estol, subida...) aparecem como "info", para conferir na aba dela.

Não bloqueia nada: a interface mostra a lista e pergunta se quer salvar mesmo assim.

    checks = aircraft_checklist(ac, project)       # project: DesignProject (ou None: só o grupo "definir")
    pending(checks)                                # o que não está ok
"""
from __future__ import annotations

from aerosim.interfaces.simulation import Check

from . import registry as rg

OK, ATT, FAIL, INFO = "ok", "atencao", "falha", "info"
DEFINE, REQS, CONS = "definir", "requisitos", "restrições"


def _length(ac) -> float:
    xs = []
    if ac.fuselage.enabled:
        xs += [ac.fuselage.x_nose, ac.fuselage.x_nose - ac.fuselage.length]
    for s in ac.surfaces:
        if s.enabled and s.sections:
            c = max(q.chord for q in s.sections)
            xs += [s.x, s.x - c]
    for b in ac.booms:
        if b.enabled:
            xs += [b.start[0], b.end[0]]
    xs += [u.x for u in ac.propulsion if u.enabled]
    return max(xs) - min(xs) if xs else 0.0


def values(ac) -> dict:
    """as grandezas do registro que o avião responde sem rodar análise"""
    from aerosim.model.universal import build_model
    units = [u for u in ac.propulsion if u.enabled]
    m_lapes = ac.payload.mass if ac.payload.enabled else 0.0
    m_liq = sum(t.volume * t.rho / 1000.0 for t in ac.tanks)
    m_bal = ac.ballast.mass if ac.ballast.enabled else 0.0
    d = dict(n_surf=sum(1 for s in ac.surfaces if s.enabled), n_motor=len(units), length=_length(ac),
             P_motor=sum(u.motor.Imax * u.battery.Voc for u in units),
             m_lapes=m_lapes, m_liquid=m_liq, m_ballast=m_bal)
    w = ac.wing
    if w is not None:
        d.update(S=w.area, b=w.span, AR=w.aspect_ratio, c_root=max((q.chord for q in w.sections), default=0.0))
    try:
        dry = float(build_model(ac).mass["m"])          # massa seca: já tem o lastro; LAPES e líquido ficam fora
    except Exception:
        dry = float("nan")
    m = dry + m_lapes + m_liq
    cp = m_lapes + m_liq + m_bal
    d.update(mass=m, cp=cp, pv=m - cp, ee=cp / (m - cp) if m - cp > 0 else float("nan"))
    return d


def define_checks(ac) -> list[Check]:
    """o que falta definir no avião (os kg da carga paga se decidem na Montagem)"""
    out = []
    add = lambda st, item, value, crit, why="", fix="": out.append(Check(st, item, value, crit, why, fix, DEFINE))
    if ac.wing is None:
        add(FAIL, "asa", "nenhuma", "uma asa", "sem asa o avião não voa", "Montagem: + Asa")
    else:
        add(OK, "asa", ac.wing.name, "uma asa")
    units = [u for u in ac.propulsion if u.enabled]
    if units:
        add(OK, "motores", str(len(units)), "≥ 1")
    else:
        add(ATT, "motores", "nenhum", "≥ 1", "planador: sem tração não decola da pista", "Montagem: + Motor")
    if ac.payload.enabled:
        n = getattr(ac.payload, "count", 1)
        if ac.payload.mass > 0:
            add(OK, "LAPES: massa", f"{ac.payload.mass:g} kg" + (f" ({n} cargas)" if n > 1 else ""), "> 0")
        else:
            add(FAIL, "LAPES: massa", "não definida", "> 0", "a LAPES está ligada sem massa",
                "Montagem → LAPES: digite a massa (ou desligue a LAPES)")
    for t in ac.tanks:
        if t.volume > 0:
            add(OK, f"{t.name}: líquido", f"{t.volume:g} L", "> 0")
        else:
            add(FAIL, f"{t.name}: líquido", "não definido", "> 0", "tanque sem líquido",
                f"Montagem → {t.name}: digite o volume (ou apague o tanque)")
    if ac.ballast.enabled:
        if ac.ballast.mass > 0:
            add(OK, "lastro: massa", f"{ac.ballast.mass:g} kg", "> 0")
        else:
            add(ATT, "lastro: massa", "0 kg", "> 0", "o lastro está ligado sem massa", "Montagem → Lastro")
    if units and ac.takeoff.sR <= 0:
        add(ATT, "decolagem: acionamento do profundor", "não ajustado", "ajustado",
            "o avião ainda não achou quando puxar o profundor na corrida",
            "Missão (modo MTOW ou decolagem) ou 'Mandar para a Montagem' na sprint ajustam sozinhos")
    return out


def project_checks(ac, project, vals: dict | None = None) -> list[Check]:
    """requisitos (massa estimada) e restrições ativas do projeto da sprint"""
    if project is None:
        return []
    vals = values(ac) if vals is None else vals
    req = project.requirements
    out = []
    m = vals.get("mass", float("nan"))
    if m == m and req.mass > 0:
        rel = (m - req.mass) / req.mass
        st = OK if abs(rel) <= 0.15 else ATT
        out.append(Check(st, "massa × massa estimada", f"{m:.2f} kg", f"≈ {req.mass:g} kg (±15 %)",
                         "" if st == OK else "a massa montada está longe da massa de partida das contas da sprint",
                         "" if st == OK else "acerte a carga paga na Montagem ou a massa estimada em Condições",
                         REQS, source="Condições e restrições… (massa estimada)"))
    for c in req.constraints:
        if not c.active:
            continue
        q = c.quantity
        if c.key in vals and vals[c.key] == vals[c.key]:
            ok, txt = c.check(vals[c.key])
            out.append(Check(OK if ok else FAIL, f"restrição: {q.label}", txt.split(f" {c.op} ")[0] + f" {q.unit}".rstrip(),
                             f"{c.op} {rg.fmt(c.value)} {q.unit}".strip(), "" if ok else "não cumpre a restrição ativa",
                             "" if ok else q.fix, CONS, source="restrições (Condições e restrições…)"))
        else:
            out.append(Check(INFO, f"restrição: {q.label}", "—", f"{c.op} {rg.fmt(c.value)} {q.unit}".strip(),
                             "precisa de uma análise", f"confira na aba de {q.stage}", CONS,
                             source="restrições (Condições e restrições…)"))
    return out


def aircraft_checklist(ac, project=None) -> list[Check]:
    vals = values(ac)
    return define_checks(ac) + project_checks(ac, project, vals)


def pending(checks: list[Check]) -> list[Check]:
    """o que não está ok (atenção ou falha); "info" não conta"""
    return [c for c in checks if c.status in (ATT, FAIL)]
