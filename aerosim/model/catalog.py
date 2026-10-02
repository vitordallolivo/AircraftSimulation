"""Itens de catálogo: motores, hélices e baterias (vários por arquivo)."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Motor:
    name: str = "motor"
    Kv: float = 310.0              # rpm/V
    Rm: float = 0.0204             # resistência (ohm)
    B: float = 32.4e-6             # atrito viscoso (N m s)
    tauc: float = 0.0155           # atrito seco (N m)
    Imax: float = 80.0             # A
    Jm: float = 1.0e-4             # inércia do rotor (kg m²)
    mass: float = 0.4              # kg
    source: str = ""               # de onde vieram os dados


@dataclass
class Propeller:
    name: str = "hélice"
    D: float = 0.381               # diâmetro (m)
    pitch: float = 0.2032          # passo (m), só informativo
    Ip: float = 5.4e-4             # inércia (kg m²)
    mass: float = 0.05
    J: list[float] = field(default_factory=list)
    CT: list[float] = field(default_factory=list)
    CP: list[float] = field(default_factory=list)
    source: str = ""


@dataclass
class Battery:
    name: str = "bateria"
    cells: int = 6
    V_cell: float = 3.7
    Rint: float = 0.035            # resistência do pacote (ohm)
    capacity_mAh: float = 5000.0
    mass: float = 0.8
    source: str = ""

    @property
    def Voc(self) -> float:
        return self.cells * self.V_cell


@dataclass
class Catalog:
    motors: list[Motor] = field(default_factory=list)
    propellers: list[Propeller] = field(default_factory=list)
    batteries: list[Battery] = field(default_factory=list)

    def motor(self, name: str) -> Motor:
        return next(m for m in self.motors if m.name == name)

    def propeller(self, name: str) -> Propeller:
        return next(p for p in self.propellers if p.name == name)

    def battery(self, name: str) -> Battery:
        return next(b for b in self.batteries if b.name == name)

    def merge(self, other: "Catalog") -> "Catalog":
        def un(a, b):
            seen = {x.name for x in a}
            return a + [x for x in b if x.name not in seen]
        return Catalog(un(self.motors, other.motors), un(self.propellers, other.propellers),
                       un(self.batteries, other.batteries))


# APC 15x8E a 6000 rpm (tabela J, C_T, C_P do fabricante, vinda do código original)
APC_15x8E = [
    (0.0000, 0.0896, 0.0299), (0.0234, 0.0883, 0.0303), (0.0468, 0.0869, 0.0307), (0.0701, 0.0853, 0.0310),
    (0.0935, 0.0836, 0.0314), (0.1169, 0.0818, 0.0316), (0.1403, 0.0799, 0.0319), (0.1637, 0.0778, 0.0320),
    (0.1871, 0.0756, 0.0321), (0.2104, 0.0732, 0.0321), (0.2338, 0.0706, 0.0320), (0.2572, 0.0679, 0.0317),
    (0.2806, 0.0651, 0.0314), (0.3040, 0.0620, 0.0309), (0.3274, 0.0588, 0.0304), (0.3507, 0.0555, 0.0296),
    (0.3741, 0.0520, 0.0288), (0.3975, 0.0484, 0.0278), (0.4209, 0.0446, 0.0266), (0.4443, 0.0407, 0.0253),
    (0.4676, 0.0368, 0.0239), (0.4910, 0.0327, 0.0224), (0.5144, 0.0286, 0.0207), (0.5378, 0.0245, 0.0189),
    (0.5612, 0.0203, 0.0170), (0.5846, 0.0162, 0.0150), (0.6079, 0.0120, 0.0129), (0.6313, 0.0079, 0.0108),
    (0.6547, 0.0039, 0.0085), (0.6781, 0.0000, 0.0062),
]


def generic_propeller(name: str, D_in: float, pitch_in: float, n: int = 25) -> Propeller:
    """hélice GENÉRICA (estimativa, não é dado de fabricante): curva com a forma da APC 15x8E
    escalada pelo passo relativo; J de tração nula ≈ 0,85 P/D."""
    PD = pitch_in / D_in
    Jz = 0.85 * PD
    s = Jz / 0.6781
    J = [Jz * i / (n - 1) for i in range(n)]
    ref_J = [r[0] for r in APC_15x8E]
    import numpy as np
    CT = np.interp(np.array(J) / s, ref_J, [r[1] for r in APC_15x8E]) * (0.75 + 0.25 * PD / 0.533)
    CP = np.interp(np.array(J) / s, ref_J, [r[2] for r in APC_15x8E]) * (PD / 0.533) ** 1.2
    D = D_in * 0.0254
    return Propeller(name=name, D=D, pitch=pitch_in * 0.0254, Ip=5.4e-4 * (D / 0.381) ** 5,
                     mass=0.05 * (D / 0.381) ** 3, J=[float(v) for v in J], CT=[float(v) for v in CT],
                     CP=[float(v) for v in CP], source="genérica (estimada a partir da APC 15x8E)")


def builtin_catalog() -> Catalog:
    apc = Propeller(name="APC 15x8E", D=0.381, pitch=0.2032, Ip=5.4e-4, mass=0.06,
                    J=[r[0] for r in APC_15x8E], CT=[r[1] for r in APC_15x8E], CP=[r[2] for r in APC_15x8E],
                    source="catálogo APC (6000 rpm)")
    return Catalog(
        motors=[
            Motor("Scorpion A-5025-310Kv", 310.0, 0.0174 + 0.003, 32.4e-6, 0.0155, 80.0, 1.0e-4, 0.53,
                  "dados do código original"),
            Motor("Genérico 500Kv", 500.0, 0.045, 2.0e-5, 0.01, 50.0, 6e-5, 0.30, "genérico (estimado)"),
            Motor("Genérico 900Kv", 900.0, 0.08, 1.0e-5, 0.006, 30.0, 3e-5, 0.15, "genérico (estimado)"),
        ],
        propellers=[apc, generic_propeller("Genérica 13x6.5", 13, 6.5), generic_propeller("Genérica 11x7", 11, 7),
                    generic_propeller("Genérica 16x10", 16, 10)],
        batteries=[
            Battery("LiPo 6S 5000", 6, 3.7, 0.035, 5000, 0.80, "dados do código original"),
            Battery("LiPo 4S 4000", 4, 3.7, 0.030, 4000, 0.45, "genérica"),
            Battery("LiPo 3S 2200", 3, 3.7, 0.025, 2200, 0.19, "genérica"),
        ],
    )
