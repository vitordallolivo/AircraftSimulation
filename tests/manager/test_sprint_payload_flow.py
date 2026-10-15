"""Da sprint à Montagem com LAPES e líquido: os kg e a posição se definem na Montagem, o CG volta ao de
projeto e a Missão 6GDL simula tudo (massa com a carga, soltura da LAPES, sloshing). Perfil NACA gerado."""
import numpy as np
import pytest

from aerosim.design import airfoils as afm
from aerosim.design import balance as bl
from aerosim.design import power as pw
from aerosim.design import tail as tl
from aerosim.design import wing as wg
from aerosim.design.flight import tune_takeoff
from aerosim.design.spec import Requirements


def test_sprint_aircraft_with_lapes_and_liquid_flies_the_full_mission(manager):
    w = wg.WingCandidate(wg.WingParams(area=1.0, span=2.4), afm.AirfoilEntry(afm.from_naca("NACA 4412")))
    ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(lapes=True, liquid=True),
                                               tl.SetCandidate(tl.TailParams(), w)), Requirements(mass=8.0))
    assert ac.payload.mass == 0.0 and ac.tanks[0].volume == 0.0          # a sprint não dá kg
    ac.payload.mass, ac.payload.x = 1.5, ac.design_cg[0] + 0.04          # Montagem: kg e onde
    ac.tanks[0].volume = 1.0
    ok, _ = bl.rebalance(ac)
    assert ok and bl.full_cg(ac)[1][0] == pytest.approx(ac.design_cg[0], abs=1e-9)
    m0 = bl.full_cg(ac)[0]
    assert tune_takeoff(ac, manager.backend)[0]
    r = manager.run("mission", ac, {})
    L = r.log
    assert r.status == "COMPLETED"
    assert L["m"][0] == pytest.approx(m0, rel=1e-6)                     # começa com a carga e o líquido
    assert L["m"][-1] == pytest.approx(m0 - 1.5, rel=1e-6)              # a LAPES saiu
    assert r.events["tdrop"] > 0 and np.isfinite(r.summary["impacto_carga_n"])
    assert "slosh_x_0" in L.keys() and np.abs(L["slosh_x_0"]).max() > 0   # o líquido balança
