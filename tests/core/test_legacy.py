"""O núcleo Zig reproduz o simulador C original (legacy/) com a mesma aeronave."""
import os
import shutil
import subprocess

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.mark.legacy
@pytest.mark.skipif(shutil.which("gcc") is None or shutil.which("make") is None, reason="sem gcc/make")
def test_takeoff_matches_legacy_c(backend, tmp_path):
    from legacy_spec import legacy_modules, spec_from_legacy
    subprocess.run(["make", "-s", "-C", os.path.join(ROOT, "legacy")], check=True)
    aeronave, P, S = legacy_modules()
    av = aeronave.padrao()
    av["escalares"].update(sR=37.5, de1=-3.0, ap_CL0=0.3978553031358884, ap_CLa=4.74713820002484)
    cfg = str(tmp_path / "leg.cfg")
    S.escreve_cfg(av, P.circuito(), cfg)
    ref = S.decolagem(cfg)
    with backend.open_session() as s:
        s.configure(dict(spec_from_legacy(av, P.circuito()), stop_takeoff=1))
        s.reset_ground()
        s.run()
        ev = s.events()
    for k_new, k_old in (("tR", "tR"), ("tLO", "tLO"), ("nLO", "nLO"), ("VLO", "VLO"), ("tHt", "tHt"),
                         ("nHt", "nHt"), ("Ipeak", "Ipico")):
        assert ev[k_new] == pytest.approx(ref[k_old], rel=2e-4, abs=2e-3), k_new
