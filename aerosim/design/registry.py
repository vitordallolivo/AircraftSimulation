"""Registro de grandezas do projeto: o que dá para medir, restringir ou variar.

Grandeza (`QUANTITIES`): nome, unidade e de onde sai (etapa). As etapas devolvem um dicionário
chave → valor (`wing_values`, `aircraft_values`) e as restrições são conferidas contra ele.

Restrição (`Constraint`): grandeza, operador (≤, ≥, =), valor e se está ativa. Liga e desliga sem
perder o valor. Ex.: envergadura ≤ 2,5 m; corrida ≤ 3 m; EE ≥ 1; massa de LAPES ≥ 2 kg.

Variável (`Variable`): uma entrada de projeto (`INPUTS`, um campo dos rascunhos das etapas) que fica
fixa (vale o que está no rascunho), variável (entre mín. e máx.: é o que o otimizador mexe) ou
calculada (sai das contas). PV e MTOW são saídas: aparecem aqui como calculadas, nunca como requisito.

    ok, txt = Constraint("b", "≤", 2.5).check(2.4)        # (True, "2,40 ≤ 2,5 m")
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

OPS = ("≤", "≥", "=")
MODES = ("fixo", "variável", "calculado")


@dataclass(frozen=True)
class Quantity:
    label: str
    unit: str = ""
    stage: str = ""            # etapa que calcula: asa | montagem | desempenho
    help: str = ""
    fix: str = ""              # o que mexer quando a restrição falha


QUANTITIES: dict[str, Quantity] = {
    "S": Quantity("área da asa", "m²", "asa", "área em planta das duas semiasas", "envergadura/corda"),
    "b": Quantity("envergadura", "m", "asa", "de ponta a ponta", "menos envergadura (mais corda para manter a área)"),
    "AR": Quantity("alongamento", "", "asa", "b²/S"),
    "c_root": Quantity("corda máxima (raiz)", "m", "asa", "com a envergadura máxima: a asa cabe num retângulo b × c "
                       "(regulamento)", "mais envergadura para a mesma área, ou menos área"),
    "V_S": Quantity("velocidade de estol", "m/s", "asa", "com a massa estimada",
                    "mais área ou perfil de C_l máximo maior"),
    "n_surf": Quantity("número de superfícies", "", "montagem", "asa, empenagens e outras ligadas"),
    "length": Quantity("comprimento total", "m", "montagem", "do nariz à ponta da cauda",
                       "braço da cauda menor (V_H com mais área)"),
    "P_motor": Quantity("potência dos motores", "W", "montagem", "elétrica máxima: corrente máx. × tensão da bateria, "
                        "somada nos motores", "motor menor ou menos motores"),
    "n_motor": Quantity("número de motores", "", "montagem"),
    "m_liquid": Quantity("massa de líquido", "kg", "montagem", "carga paga em água"),
    "m_lapes": Quantity("massa de LAPES", "kg", "montagem", "carga paga lançada"),
    "m_ballast": Quantity("massa de lastro", "kg", "montagem", "carga paga sólida"),
    "sm": Quantity("margem estática", "% CMA", "montagem"),
    "s_to": Quantity("corrida de decolagem", "m", "desempenho", "com a massa montada",
                     "mais tração, mais área ou menos massa"),
    "V_max": Quantity("velocidade máxima", "m/s", "desempenho"),
    "RC": Quantity("razão de subida máxima", "m/s", "desempenho", "", "mais tração ou menos arrasto"),
    "TW": Quantity("tração/peso estática", "", "desempenho"),
    "mass": Quantity("massa montada", "kg", "montagem", "saída: PV + CP"),
    "pv": Quantity("PV (peso vazio)", "kg", "montagem", "saída: tudo menos a carga paga"),
    "cp": Quantity("CP (carga paga)", "kg", "montagem", "saída: lastro + líquido + LAPES"),
    "ee": Quantity("EE (eficiência estrutural)", "", "montagem", "saída: CP / PV", "PV menor ou CP maior"),
    "mtow": Quantity("MTOW", "kg", "desempenho", "saída: a maior massa que decola na corrida restrita"),
}


def fmt(v: float) -> str:
    if v is None or (isinstance(v, float) and not math.isfinite(v)):
        return "—"
    return f"{v:.3g}".replace(".", ",") if abs(v) < 1000 else f"{v:.0f}"


@dataclass
class Constraint:
    key: str = "b"
    op: str = "≤"
    value: float = 0.0
    active: bool = True
    tol: float = 0.02          # "=": tolerância relativa

    @property
    def quantity(self) -> Quantity:
        return QUANTITIES.get(self.key, Quantity(self.key))

    def holds(self, x: float) -> bool:
        if x is None or not math.isfinite(x):
            return False
        if self.op == "≤":
            return x <= self.value + 1e-9
        if self.op == "≥":
            return x >= self.value - 1e-9
        return abs(x - self.value) <= self.tol * max(abs(self.value), 1e-9)

    def text(self) -> str:
        q = self.quantity
        return f"{q.label} {self.op} {fmt(self.value)} {q.unit}".strip()

    def check(self, x: float) -> tuple[bool, str]:
        return self.holds(x), f"{fmt(x)} {self.op} {fmt(self.value)} {self.quantity.unit}".strip()


def default_constraints() -> list[Constraint]:
    """as restrições de partida (as desligadas ficam à mão para ligar)"""
    return [Constraint("V_S", "≤", 11.0), Constraint("b", "≤", 2.5), Constraint("s_to", "≤", 50.0),
            Constraint("length", "≤", 2.0, active=False), Constraint("S", "≤", 1.0, active=False),
            Constraint("P_motor", "≤", 700.0, active=False), Constraint("n_surf", "≤", 3, active=False),
            Constraint("n_motor", "≤", 1, active=False), Constraint("ee", "≥", 1.0, active=False),
            Constraint("m_liquid", "≥", 1.0, active=False), Constraint("m_lapes", "≥", 1.0, active=False),
            Constraint("RC", "≥", 1.0, active=False)]


def active(constraints: list[Constraint], key: str, op: str | None = None) -> Constraint | None:
    return next((c for c in constraints if c.active and c.key == key and (op is None or c.op == op)), None)


def checks(constraints: list[Constraint], values: dict, stage: str | None = None) -> list[tuple[Constraint, bool, str]]:
    """(restrição, cumpre, texto) das restrições ativas que estas grandezas respondem"""
    out = []
    for c in constraints:
        if not c.active or c.key not in values:
            continue
        if stage is not None and c.quantity.stage != stage and not (stage == "montagem" and c.quantity.stage ==
                                                                     "desempenho"):
            continue
        ok, txt = c.check(values[c.key])
        out.append((c, ok, txt))
    return out


# ------------------------------------------------------------------ variáveis (entradas das etapas)
@dataclass(frozen=True)
class Input:
    path: str                  # onde mora no projeto: "<rascunho>.<campo>"
    label: str
    unit: str = ""
    lo: float = 0.0            # faixa sugerida para "variável"
    hi: float = 1.0
    integer: bool = False


INPUTS: dict[str, Input] = {
    "wing.span": Input("wing_draft.span", "envergadura", "m", 1.0, 3.0),
    "wing.area": Input("wing_draft.area", "área da asa", "m²", 0.3, 1.5),
    "wing.taper": Input("wing_draft.taper", "afilamento", "", 0.3, 1.0),
    "wing.rect_frac": Input("wing_draft.rect_frac", "trecho retangular", "", 0.0, 1.0),
    "wing.alpha_cruise": Input("wing_draft.alpha_cruise", "ângulo de cruzeiro", "°", -2.0, 6.0),
    "wing.airfoil": Input("wing_draft.airfoil", "perfil da asa (raiz)", "lista"),
    "wing.airfoil_tip": Input("wing_draft.airfoil_tip", "perfil da ponta (vazio = o da raiz)", "lista"),
    "power.motor": Input("power_draft.motor", "motor", "lista"),
    "power.propeller": Input("power_draft.propeller", "hélice", "lista"),
    "power.layout": Input("power_draft.layout", "motores (arranjo)", "lista"),
    "power.tilt": Input("power_draft.tilt", "inclinação do motor", "°", 0.0, 12.0),
    "power.motors": Input("power_draft.wing_motors", "nº de motores (o arranjo manda: nariz/propulsora 1, asa aos pares)",
                          "", 1.0, 8.0, integer=True),
    "power.ballast": Input("power_draft.ballast", "lastro", "kg", 0.0, 10.0),
    "power.liquid": Input("power_draft.liquid", "líquido", "L", 0.0, 5.0),
    "power.lapes": Input("power_draft.lapes", "LAPES", "kg", 0.0, 5.0),
    "req.V_cruise": Input("requirements.V_cruise", "velocidade de cruzeiro", "m/s", 10.0, 25.0),
    "req.mass": Input("requirements.mass", "massa estimada (ponto de partida)", "kg", 2.0, 20.0),
}


@dataclass
class Variable:
    key: str = "wing.span"
    mode: str = "fixo"
    lo: float = 0.0
    hi: float = 1.0
    options: list[str] = field(default_factory=list)   # "lista": os itens que o otimizador pode escolher

    @property
    def input(self) -> Input:
        return INPUTS.get(self.key, Input(self.key, self.key))


def default_variables() -> list[Variable]:
    out = [Variable(k, "fixo", i.lo, i.hi) for k, i in INPUTS.items()]
    for v in out:
        if v.key == "req.mass":
            v.mode = "calculado"           # o ponto de projeto acerta a massa sozinho
    return out


def get_input(project, key: str):
    obj, _, name = INPUTS[key].path.partition(".")
    return getattr(getattr(project, obj), name)


def set_input(project, key: str, value) -> None:
    obj, _, name = INPUTS[key].path.partition(".")
    target = getattr(project, obj)
    cur = getattr(target, name)
    setattr(target, name, type(cur)(value) if isinstance(cur, (int, float)) and not isinstance(cur, bool) else value)


# ------------------------------------------------------------------ valores que as etapas devolvem
def wing_values(r: dict) -> dict:
    c = r.get("chord")
    return {"S": r.get("S"), "b": r.get("b"), "AR": r.get("AR"), "V_S": r.get("V_stall"),
            "c_root": float(max(c)) if c is not None and len(c) else None}


def aircraft_values(ac, asm: dict, pf: dict | None, pp=None) -> dict:
    """grandezas do avião montado (asm: `power.assemble`; pf: `power.performance`)"""
    units = [u for u in ac.propulsion if u.enabled]
    P = sum(u.motor.Imax * u.battery.Voc for u in units)
    d = {"n_surf": sum(1 for s in ac.surfaces if s.enabled), "length": asm.get("length"), "P_motor": P,
         "n_motor": len(units), "sm": asm.get("sm"), "mass": asm.get("mass"), "pv": asm.get("empty"),
         "cp": asm.get("payload")}
    d["ee"] = d["cp"] / d["pv"] if d.get("pv") else float("nan")
    w = ac.wing
    if w is not None:
        d.update(S=w.area, b=w.span, AR=w.aspect_ratio, V_S=asm.get("Vs"),
                 c_root=max((q.chord for q in w.sections), default=0.0))
    if pp is not None:
        d.update(m_liquid=pp.liquid * 1.0, m_lapes=pp.lapes, m_ballast=pp.ballast)
    if pf:
        d.update(s_to=pf.get("s_to"), V_max=pf.get("Vmax"), RC=pf.get("RC_max"), TW=pf.get("TW"),
                 mtow=pf.get("mtow_runway"))
    return d


# ------------------------------------------------------------------ limites das variáveis
# restrição → entrada que ela limita (o otimizador não precisa procurar fora do que a restrição deixa)
CONSTRAINT_INPUT = {"b": "wing.span", "S": "wing.area", "n_motor": "power.motors"}


def sae_constraints(runway: float = 6.0) -> list[Constraint]:
    """o padrão do projeto novo (SAE AeroDesign): decolar em `runway` m; a asa cabe num retângulo (envergadura e
    corda máximas — os valores são do regulamento do ano: confira e ajuste em Condições e restrições)"""
    cs = default_constraints()
    for c in cs:
        if c.key == "s_to":
            c.value, c.active = runway, True
    cs.insert(2, Constraint("c_root", "≤", 0.5, active=False))
    return cs


def bounds_from_constraints(project) -> list[str]:
    """leva as restrições ativas para os limites das variáveis (≤ → máx., ≥ → mín., = → os dois); devolve o
    que mudou"""
    out = []
    for c in project.requirements.constraints:
        if not c.active:
            continue
        key = CONSTRAINT_INPUT.get(c.key)
        v = next((v for v in project.variables if v.key == key), None)
        if v is None:
            continue
        if c.op in ("≤", "="):
            v.hi = c.value
        if c.op in ("≥", "="):
            v.lo = c.value
        if v.lo > v.hi:
            v.lo = v.hi
        out.append(f"{v.input.label}: {v.lo:g}…{v.hi:g}")
    return out


def check_bounds(project) -> list[str]:
    """variável física (contínua) marcada como 'variável' precisa de mín. e máx. finitos, mín. < máx.; lista
    precisa de opções"""
    bad = []
    for v in project.variables:
        if v.mode != "variável":
            continue
        if v.input.unit == "lista":
            continue                                       # lista sem nada marcado = todos
        elif not (math.isfinite(v.lo) and math.isfinite(v.hi)) or v.lo >= v.hi:
            bad.append(f"{v.input.label}: limites [{v.lo:g}, {v.hi:g}] (precisa de mín. < máx.)")
    return bad
