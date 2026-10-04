"""Requisitos (o que o avião tem de cumprir) e regras de projeto (como as peças se montam).

Os requisitos dão o C_L de cruzeiro, o Re, a velocidade de estol máxima, a envergadura máxima e a
pista; as regras dão massas por área/comprimento, o tamanho da fuselagem (pod), onde ficam o motor e
o trem. Todas as etapas leem daqui — mudar um requisito muda o que as etapas mostram.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from aerosim.model.atmosphere import isa_density

from .fields import F

G0 = 9.80665
MU_AIR = 1.81e-5


@dataclass
class Requirements:
    mass: float = F(10.0, "massa total estimada", "kg", "MTOW esperado: dá o C_L de cruzeiro e a carga alar", 0.2, 60, 0.1)
    payload: float = F(4.0, "carga paga", "kg", "vai no CG (não mexe no equilíbrio quando muda)", 0, 40, 0.1)
    V_cruise: float = F(15.0, "velocidade de cruzeiro", "m/s", "", 3, 60, 0.5)
    V_stall_max: float = F(11.0, "estol máximo", "m/s", "a velocidade de estol (massa total) não pode passar disto",
                           3, 40, 0.5)
    density_altitude: float = F(600.0, "altitude-densidade (AD)", "m", "atmosfera padrão com a densidade do dia",
                                -500, 4000, 50)
    span_max: float = F(2.5, "envergadura máxima", "m", "0 = sem limite (regulamento, hangar, caixa)", 0, 8, 0.05)
    length_max: float = F(0.0, "comprimento máximo", "m", "0 = sem limite", 0, 6, 0.05)
    takeoff_run: float = F(50.0, "pista disponível", "m", "a corrida de decolagem tem de caber nela", 5, 300, 1)
    mu_roll: float = F(0.04, "atrito de rolamento", "", "pista: grama ≈ 0,08, asfalto ≈ 0,03", 0, 0.3, 0.005)

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
        b = f"b ≤ {self.span_max:g} m" if self.span_max > 0 else "b livre"
        return (f"m = {self.mass:g} kg · V = {self.V_cruise:g} m/s · V_S ≤ {self.V_stall_max:g} m/s · {b} · "
                f"AD {self.density_altitude:.0f} m (ρ = {self.rho:.3f}) · pista {self.takeoff_run:g} m")


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
    de_max: float = F(20.0, "curso do profundor", "°", "deflexão máxima usada no equilíbrio", 5, 40, 1)
    da_max: float = F(20.0, "curso do aileron", "°", "", 5, 40, 1)


def cruise_CL(req: Requirements, S: float) -> float:
    return req.weight / (req.q() * S) if S > 0 else float("nan")


def stall_speed(req: Requirements, S: float, CLmax: float, mass: float | None = None) -> float:
    m = req.mass if mass is None else mass
    return math.sqrt(2 * m * G0 / (req.rho * S * CLmax)) if S > 0 and CLmax > 0 else float("nan")
