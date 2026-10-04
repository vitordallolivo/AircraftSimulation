"""O avião só sai da sprint se voar: a decolagem do núcleo 6GDL (o mesmo otimizador da aba Missão) acha o
acionamento do profundor, a deflexão e, se precisar, o profundor picando na corrida — e isso fica no avião
(`takeoff.sR`, `de1`, `de0`). O AeroDrive e a Missão decolam com esses números."""
from __future__ import annotations

import math

from aerosim.manager import takeoff_opt as TO


def tune_takeoff(ac, backend) -> tuple[bool, str]:
    """(decolou?, explicação); com sucesso, grava a decolagem achada no avião"""
    best, _ = TO.optimize(backend, ac, ac.airfield.x_warning, ac.airfield.z_warning)
    if not best.ok:
        return False, (f"não decola na pista ({best.status.lower()}; x_warning {ac.airfield.x_warning:g} m, "
                       f"z_warning {ac.airfield.z_warning:g} m)")
    if TO.pitch_control(ac) and math.isfinite(best.s):
        ac.takeoff.sR, ac.takeoff.de1 = float(round(best.s, 2)), float(round(best.de, 2))
        ac.takeoff.de0 = float(round(best.de0, 2)) if math.isfinite(best.de0) else ac.takeoff.de0
    hold = f", profundor {best.de0:+g}° na corrida" if math.isfinite(best.de0) else ""
    return True, f"decola em {best.n_dec:.1f} m (aciona o profundor em {best.s:.1f} m, {best.de:g}°{hold})"
