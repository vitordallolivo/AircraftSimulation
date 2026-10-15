"""Sonda dos modificadores (aerosim_probe_ground) e a ferramenta de linha de comando tools/probe.py."""
import os
import subprocess
import sys

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_probe_ground_is_mccormick(backend):
    h, b = np.array([0.0, 0.22, 1.0, 50.0]), 2.2
    phi = backend.probe_ground(1, h, b)
    r = 16 * np.maximum(h, 0.01) / b
    assert np.allclose(phi, r * r / (1 + r * r), rtol=0, atol=1e-15)       # a fórmula do McCormick
    assert phi[1] == 2.56 / 3.56 or abs(phi[1] - 2.56 / 3.56) < 1e-12
    assert (backend.probe_ground(0, h, b) == 1.0).all()                    # desligado


def test_probe_cli_writes_csv(tmp_path):
    out = tmp_path / "solo.csv"
    png = tmp_path / "solo.png"
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "probe.py"), "solo", "--b", "2.2",
                        "--h", "0.02:0.2:0.02", "--csv", str(out), "--png", str(png)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    lines = out.read_text().splitlines()
    assert lines[0] == "h_m,h_sobre_b,fator_CDi" and len(lines) == 11 and png.stat().st_size > 1000
