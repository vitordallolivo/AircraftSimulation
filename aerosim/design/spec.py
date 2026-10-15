"""Condições e restrições (o que o avião tem de cumprir) e regras de projeto (como as peças se montam).

As condições dão o ponto de partida: massa estimada (o ponto de projeto a acerta), velocidade de cruzeiro,
altitude-densidade e atrito da pista. Os limites são restrições (`registry.Constraint`) que se ligam e
desligam, com operador: envergadura ≤, estol ≤, corrida ≤ (a pista), EE ≥, LAPES ≥... As regras dão
massas por área/comprimento, o tamanho da fuselagem (pod), onde ficam o motor e o trem.

`span_max`, `V_stall_max`, `length_max` e `takeoff_run` continuam existindo como leitura das restrições
(desligada = sem limite) para as contas das etapas.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from aerosim.model.atmosphere import isa_density

from .fields import F
from .registry import Constraint, active, default_constraints

NO_RUNWAY = 1000.0      # corrida sem restrição (m): o MTOW passa a vir das outras restrições

G0 = 9.80665
MU_AIR = 1.81e-5


@dataclass
class Requirements:
    mass: float = F(10.0, "massa estimada (ponto de partida)", "kg", "dá o C_L de cruzeiro e a carga alar das primeiras "
                    "etapas; o ponto de projeto acerta a massa de verdade (o MTOW é saída, não requisito)", 0.2, 60, 0.1)
    V_cruise: float = F(15.0, "velocidade de cruzeiro", "m/s", "", 3, 60, 0.5)
    density_altitude: float = F(600.0, "altitude-densidade (AD)", "m", "atmosfera padrão com a densidade do dia",
                                -500, 4000, 50)
    mu_roll: float = F(0.04, "atrito de rolamento", "", "pista: grama ≈ 0,08, asfalto ≈ 0,03", 0, 0.3, 0.005)
    V_turn: float = F(0.0, "V da curva", "m/s", "a velocidade da curva sustentada (restrição de fator de carga); "
                      "0 = a de cruzeiro", 0, 60, 0.5)
    mu_brake: float = F(0.3, "atrito na frenagem", "", "pouso: rodas freando na pista", 0.05, 1.0, 0.05)
    constraints: list[Constraint] = field(default_factory=default_constraints)

    # ---- os limites que as contas usam, lidos das restrições ativas (desligada = sem limite)
    def _limit(self, key: str, op: str, off: float) -> float:
        c = active(self.constraints, key, op)
        return c.value if c is not None else off

    def _set_limit(self, key: str, op: str, v: float) -> None:
        c = next((c for c in self.constraints if c.key == key and c.op == op), None)
        if c is None:
            self.constraints.append(Constraint(key, op, v))
        else:
            c.value, c.active = v, True

    span_max = property(lambda s: s._limit("b", "≤", 0.0), lambda s, v: s._set_limit("b", "≤", v))
    V_stall_max = property(lambda s: s._limit("V_S", "≤", math.inf), lambda s, v: s._set_limit("V_S", "≤", v))
    length_max = property(lambda s: s._limit("length", "≤", 0.0), lambda s, v: s._set_limit("length", "≤", v))
    takeoff_run = property(lambda s: s._limit("s_to", "≤", NO_RUNWAY), lambda s, v: s._set_limit("s_to", "≤", v))

    @staticmethod
    def migrate(data: dict) -> dict:
        """projetos antigos: envergadura/estol/comprimento/pista eram campos — viram restrições"""
        old = {k: data.pop(k) for k in ("span_max", "V_stall_max", "length_max", "takeoff_run") if k in data}
        if old and "constraints" not in data:
            cs = default_constraints()
            for key, (q, op) in {"span_max": ("b", "≤"), "V_stall_max": ("V_S", "≤"), "length_max": ("length", "≤"),
                                 "takeoff_run": ("s_to", "≤")}.items():
                if key in old:
                    c = next(c for c in cs if c.key == q and c.op == op)
                    v = float(old[key])
                    c.value, c.active = (v, v > 0) if key in ("span_max", "length_max") else (v, True)
            from aerosim.model.serialize import to_dict
            data["constraints"] = [to_dict(c) for c in cs]
        return data

    @property
    def rho(self) -> float:
        return isa_density(self.density_altitude)

    @property
    def weight(self) -> float:
        return self.mass * G0

    def q(self, V: float | None = None) -> float:
        V = self.V_cruise if V is None else V
        return 0.5 * self.rho * V * V

    def reynolds(self, chord: float, V: float | None = None) -> float:
        V = self.V_cruise if V is None else V
        return self.rho * V * chord / MU_AIR

    def summary(self) -> str:
        on = [c.text() for c in self.constraints if c.active]
        return (f"partida m = {self.mass:g} kg · V = {self.V_cruise:g} m/s · AD {self.density_altitude:.0f} m "
                f"(ρ = {self.rho:.3f}) · restrições: " + ("; ".join(on) if on else "nenhuma"))


@dataclass
class DesignRules:
    wing_density: float = F(1.1, "massa da asa por área", "kg/m²", "estrutura + entelagem", 0.1, 6, 0.05)
    tail_density: float = F(0.7, "massa da empenagem por área", "kg/m²", "", 0.1, 6, 0.05)
    boom_density: float = F(0.12, "massa do tubo por metro", "kg/m", "", 0.01, 2, 0.01)
    fuselage_width: float = F(0.14, "largura da fuselagem", "m", "pod do nariz até o bordo de fuga da asa", 0.03, 0.6, 0.01)
    fuselage_height: float = F(0.16, "altura da fuselagem", "m", "", 0.03, 0.6, 0.01)
    fuselage_cd_wet: float = F(0.04, "C_D da fuselagem (área molhada)", "", "pod curto com trem: ≈ 0,04", 0.005, 0.2,
                               0.005)
    fuselage_density: float = F(0.7, "massa da fuselagem por metro", "kg/m", "", 0.05, 5, 0.05)
    systems_mass: float = F(0.35, "sistemas", "kg", "receptor, servos, fiação", 0, 5, 0.05)
    gear_mass: float = F(0.35, "trem de pouso", "kg", "", 0, 5, 0.05)
    nose_length: float = F(0.30, "nariz à frente da asa", "m", "do bordo de ataque da asa até a hélice (tratora)",
                           0.05, 1.5, 0.01)
    wing_z: float = F(-0.10, "altura da asa", "m", "z do bordo de ataque (− = acima da fuselagem)", -0.5, 0.5, 0.01)
    prop_clearance: float = F(0.05, "folga da hélice ao chão", "m", "", 0.0, 0.5, 0.01)
    main_gear_aft: float = F(0.06, "trem principal atrás do CG", "m", "≈ 15° de tombamento", 0.0, 0.5, 0.01)
    track: float = F(0.45, "bitola do trem", "m", "", 0.1, 2, 0.01)
    de_max: float = F(20.0, "profundor: curso para cabrar", "°", "bordo de fuga para cima (rotação, C_L,max)", 5, 40, 1)
    de_down: float = F(15.0, "profundor: curso para picar", "°", "cursos assimétricos: picar costuma ser menor; segura "
                       "o nariz na corrida do motor inclinado", 2, 40, 1)
    da_max: float = F(20.0, "aileron: curso para cima", "°", "", 5, 40, 1)
    da_down: float = F(12.0, "aileron: curso para baixo", "°", "aileron diferencial: desce menos do que sobe (menos "
                       "guinada adversa)", 2, 40, 1)


def cruise_CL(req: Requirements, S: float) -> float:
    return req.weight / (req.q() * S) if S > 0 else float("nan")


def stall_speed(req: Requirements, S: float, CLmax: float, mass: float | None = None) -> float:
    m = req.mass if mass is None else mass
    return math.sqrt(2 * m * G0 / (req.rho * S * CLmax)) if S > 0 and CLmax > 0 else float("nan")
