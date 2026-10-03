"""O que a aeronave tem — as abas de análise usam isto para decidir o que mostrar.

Ex.: sem EH não há dimensionamento de EH; com elevon o mesmo comando faz arfagem e rolagem;
sem tanques não há variação de CG pelo líquido; superfícies verticais na ponta da asa são
dispositivos de ponta (winglets/placas)."""
from __future__ import annotations

from dataclasses import dataclass, field

from .aircraft import Aircraft, ControlSurface, LiftingSurface


@dataclass
class Features:
    wing: LiftingSurface | None = None
    htail: LiftingSurface | None = None           # EH (ou cauda em V)
    vtail: list[LiftingSurface] = field(default_factory=list)   # derivas (sem os dispositivos de ponta)
    tip_devices: list[LiftingSurface] = field(default_factory=list)   # derivas soltas na ponta da asa
    devices: list = field(default_factory=list)   # (superfície, WingDevice) presos às superfícies
    pitch: tuple[LiftingSurface, ControlSurface] | None = None   # comando de arfagem
    roll: tuple[LiftingSurface, ControlSurface] | None = None
    yaw: tuple[LiftingSurface, ControlSurface] | None = None
    liquid: bool = False          # tanques com líquido
    slosh: bool = False           # líquido livre (sloshing ligado)
    payload: bool = False         # carga que é solta
    multi_engine: bool = False    # mais de um motor fora do plano de simetria
    gear: bool = True

    @property
    def tailless(self) -> bool:
        return self.htail is None

    @property
    def pitch_kind(self) -> str:
        return self.pitch[1].kind if self.pitch else ""

    @property
    def roll_kind(self) -> str:
        return self.roll[1].kind if self.roll else ""

    @property
    def yaw_kind(self) -> str:
        return self.yaw[1].kind if self.yaw else ""

    @property
    def has_tip_devices(self) -> bool:
        return bool(self.tip_devices or self.wing_devices)

    @property
    def wing_devices(self) -> list:
        return [(s, d) for s, d in self.devices if s is self.wing]

    @property
    def tip_h_over_b(self) -> float:
        """altura média dos dispositivos da asa / envergadura"""
        if self.wing is None or self.wing.span <= 0:
            return 0.0
        hs = [s.semispan for s in self.tip_devices] + [d.height for _, d in self.wing_devices]
        return sum(hs) / len(hs) / self.wing.span if hs else 0.0

    def summary(self) -> str:
        parts = ["asa voadora (sem EH)" if self.tailless else f"EH: {self.htail.name}"]
        if self.pitch:
            parts.append(f"arfagem por {self.pitch_kind}")
        if self.roll:
            parts.append(f"rolagem por {self.roll_kind}")
        parts.append(f"guinada por {self.yaw_kind}" if self.yaw else "sem leme")
        if self.tip_devices:
            parts.append(f"{len(self.tip_devices)} deriva(s) na ponta da asa")
        for s, d in self.devices:
            parts.append(f"{d.kind} em {s.name} (η = {d.eta:.2f}, h = {d.height:.3f} m, cant {d.cant:g}°)")
        if self.liquid:
            parts.append("líquido " + ("livre (sloshing)" if self.slosh else "travado"))
        if self.payload:
            parts.append("carga lançável")
        return "; ".join(parts)


def _ok(s: LiftingSurface) -> bool:
    return s.enabled and len(s.sections) > 1


def features(ac: Aircraft) -> Features:
    f = Features()
    surfs = [s for s in ac.surfaces if _ok(s)]
    f.wing = next((s for s in surfs if s.role == "wing"), None)
    f.htail = next((s for s in surfs if s.role == "htail"), None)
    bw = f.wing.semispan if f.wing is not None else 0.0
    for s in surfs:
        if not s.vertical or s.role == "wing":
            continue
        at_tip = f.wing is not None and bw > 0 and abs(abs(s.y) - (f.wing.y + bw)) < 0.08 * bw
        (f.tip_devices if at_tip else f.vtail).append(s)

    def find(kinds):
        for s in surfs:
            for c in s.controls:
                if c.kind in kinds:
                    return (s, c)
        return None
    f.devices = [(s, d) for s in surfs if not s.vertical for d in s.devices if d.enabled and d.height > 0]
    f.pitch = find(("elevator",)) or find(("elevon", "ruddervator"))
    f.roll = find(("aileron",)) or find(("elevon",))
    f.yaw = find(("rudder",)) or find(("ruddervator",))
    f.liquid = any(t.fill > 0 for t in ac.tanks)
    f.slosh = f.liquid and ac.sim.slosh
    f.payload = bool(ac.payload.enabled)
    units = [u for u in ac.propulsion if u.enabled]
    f.multi_engine = len(units) > 1 and any(abs(u.y) > 0.05 for u in units)
    f.gear = bool(ac.gear.legs())
    return f
