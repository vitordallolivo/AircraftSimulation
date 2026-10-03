"""Critérios de aprovação da aba Estabilidade — vêm de uma norma ou do usuário.

`Criteria` guarda os limites de "nível 1" (o que é considerado aprovado). `mil_8785c(classe, fase)`
preenche pela MIL-F-8785C; `custom(...)` usa o que foi digitado na aba. `evaluate(modos, crit)`
compara e devolve uma linha por critério. Margem estática, deflexões e vento cruzado não são
definidos pela norma e são sempre entradas da aba.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass

from .controls import ROLL_REQ


@dataclass
class Criteria:
    sp_zeta_min: float = 0.30          # curto período
    sp_zeta_max: float = 2.00
    ph_zeta_min: float = 0.04          # fugóide
    dr_zeta_min: float = 0.08          # dutch roll
    dr_zw_min: float = 0.15
    dr_wn_min: float = 0.4
    roll_tau_max: float = 1.4          # rolamento (s)
    spiral_t2_min: float = 20.0        # espiral: tempo para dobrar (s)
    roll_phi: float = 60.0             # rolagem: ângulo (°) ...
    roll_t: float = 1.7                # ... em t (s)
    source: str = "definido na aba"
    norm: str = ""                     # "MIL-F-8785C" quando vier da norma (com níveis 2 e 3)
    cls: str = "I"
    cat: str = "B"
    use: tuple = ("sp", "ph", "dr", "roll_tau", "spiral", "roll")   # critérios ligados; os outros só informam

    def on(self, key: str) -> bool:
        return key in self.use

    def as_dict(self) -> dict:
        return asdict(self)


# grupos de critérios que podem ser ligados/desligados: (chave, rótulo, campos)
GROUPS = [("sp", "curto período", ("sp_zeta_min", "sp_zeta_max")), ("ph", "fugóide", ("ph_zeta_min",)),
          ("dr", "dutch roll", ("dr_zeta_min", "dr_zw_min", "dr_wn_min")), ("roll_tau", "rolamento", ("roll_tau_max",)),
          ("spiral", "espiral", ("spiral_t2_min",)), ("roll", "tempo de rolagem", ("roll_phi", "roll_t"))]

FIELDS = [  # (campo, rótulo, unidade)
    ("sp_zeta_min", "curto período: ζ mínimo", ""), ("sp_zeta_max", "curto período: ζ máximo", ""),
    ("ph_zeta_min", "fugóide: ζ mínimo", ""), ("dr_zeta_min", "dutch roll: ζ mínimo", ""),
    ("dr_zw_min", "dutch roll: ζ·ω_n mínimo", "rad/s"), ("dr_wn_min", "dutch roll: ω_n mínimo", "rad/s"),
    ("roll_tau_max", "rolamento: constante de tempo máxima", "s"),
    ("spiral_t2_min", "espiral: tempo mínimo para dobrar", "s"),
    ("roll_phi", "rolagem: inclinar até", "°"), ("roll_t", "rolagem: em no máximo", "s"),
]


def mil_8785c(cls: str = "I", cat: str = "B") -> Criteria:
    """nível 1 da MIL-F-8785C (1980) por classe (I–IV) e fase de voo (A, B, C)"""
    sp = (0.35, 1.30) if cat in "AC" else (0.30, 2.00)
    if cat == "A":
        dr = (0.19, 0.35, 1.0) if cls in ("I", "IV") else (0.19, 0.35, 0.5)
    elif cat == "B":
        dr = (0.08, 0.15, 0.4)
    else:
        dr = (0.08, 0.15, 1.0) if cls in ("I", "IV") else (0.08, 0.10, 0.4)
    if cat == "B" or (cat == "A" and cls in ("II", "III")) or (cat == "C" and cls == "III"):
        tau = 1.4
    else:
        tau = 1.0
    phi, t = ROLL_REQ[cls][cat]
    return Criteria(sp[0], sp[1], 0.04, dr[0], dr[1], dr[2], tau, 12.0 if cat in "AC" else 20.0, phi, t,
                    source=f"MIL-F-8785C, classe {cls}, fase {cat}, nível 1", norm="MIL-F-8785C", cls=cls, cat=cat)


def none() -> Criteria:
    """sem norma: todos os critérios desligados (a aba só informa os valores)"""
    return Criteria(source="nenhum critério (só valores)", use=())


def evaluate(m: dict, c: Criteria) -> list[dict]:
    """[{criterio, valor, limite, ok, nivel}] — nível só quando o critério é a MIL-F-8785C;
    ok = None quando o critério está desligado"""
    from .dynamic import mil_check
    levels = {r["criterio"]: r["nivel"] for r in mil_check(m, c.cls, c.cat)} if c.norm else {}
    rows = []
    sp = m.get("curto_periodo") or {}
    if sp.get("im", 0) > 0:
        z = sp["zeta"]
        rows.append(dict(criterio="ζ curto período", valor=z, limite=f"{c.sp_zeta_min:g} a {c.sp_zeta_max:g}",
                         ok=c.sp_zeta_min <= z <= c.sp_zeta_max))
    ph = m.get("fugoide") or {}
    if ph:
        z = ph.get("zeta", float("nan"))
        rows.append(dict(criterio="ζ fugóide", valor=z, limite=f"≥ {c.ph_zeta_min:g}", ok=z >= c.ph_zeta_min))
    dr = m.get("dutch_roll") or {}
    if dr:
        z, wn = dr["zeta"], dr["wn"]
        rows.append(dict(criterio="dutch roll ζ / ζω_n / ω_n", valor=[z, z * wn, wn],
                         limite=f"≥ {c.dr_zeta_min:g} / {c.dr_zw_min:g} / {c.dr_wn_min:g}",
                         ok=z >= c.dr_zeta_min and z * wn >= c.dr_zw_min and wn >= c.dr_wn_min))
    ro = m.get("rolamento") or {}
    if ro and math.isfinite(ro.get("tau", float("nan"))):
        t = ro["tau"] if ro["tau"] > 0 else float("inf")
        rows.append(dict(criterio="τ_R rolamento (s)", valor=t, limite=f"≤ {c.roll_tau_max:g} s", ok=t <= c.roll_tau_max))
    es = m.get("espiral") or {}
    if es:
        t2 = es.get("t_double", float("nan"))
        t2 = float("inf") if not math.isfinite(t2) else t2
        rows.append(dict(criterio="espiral: tempo para dobrar (s)", valor=t2, limite=f"≥ {c.spiral_t2_min:g} s",
                         ok=t2 >= c.spiral_t2_min))
    keys = {"ζ curto período": "sp", "ζ fugóide": "ph", "dutch roll ζ / ζω_n / ω_n": "dr",
            "τ_R rolamento (s)": "roll_tau", "espiral: tempo para dobrar (s)": "spiral"}
    for r in rows:
        r["nivel"] = levels.get(r["criterio"])
        if not c.on(keys[r["criterio"]]):
            r["ok"], r["limite"], r["nivel"] = None, "—", None
    return rows
