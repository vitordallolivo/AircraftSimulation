"""Roda um avião com os modificadores dele e sem cada um (um de cada vez) e mostra a diferença na decolagem.
Usa o simulador direto (manager → núcleo), sem GUI.

    python tools/modcheck.py data/aircraft/Convencional_original.json
    python tools/modcheck.py meu_aviao.json --sem-solo          # compara também com o efeito solo desligado
"""
from __future__ import annotations

import argparse
import copy
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

KEYS = (("n_dec", "decolou em (m)"), ("V_ao_sair_do_chao", "V ao sair do chão (m/s)"),
        ("n_saiu_do_chao", "saiu do chão em (m)"), ("folga_de_pista", "folga de pista (m)"))


def takeoff(manager, ac) -> dict:
    r = manager.run("mission", ac, {"mode": "só decolagem"})
    return {k: r.summary.get(k, float("nan")) for k, _ in KEYS}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("aviao")
    ap.add_argument("--sem-solo", action="store_true", help="inclui o caso sem nenhum efeito solo")
    args = ap.parse_args(argv)
    from aerosim.data import load_aircraft
    from aerosim.manager import SimulationManager
    from aerosim.model import modifiers as mods
    ac = load_aircraft(args.aviao)
    man = SimulationManager()
    cases = [("como está: " + "; ".join(mods.describe(ac)), ac)]
    for i, m in enumerate(ac.modifiers):
        v = copy.deepcopy(ac)
        v.modifiers.pop(i)
        cases.append((f"sem {m.kind}", v))
    if args.sem_solo:
        v = copy.deepcopy(ac)
        v.modifiers = [m for m in v.modifiers if not (m.info and m.info.category == "solo")]
        cases.append(("sem efeito solo", v))
    base = None
    print(f"{'caso':48s}" + "".join(f"{lab:>26s}" for _, lab in KEYS))
    for name, v in cases:
        r = takeoff(man, v)
        base = base or r
        cells = "".join(f"{r[k]:>15.3f} ({r[k] - base[k]:+7.3f})" for k, _ in KEYS)
        print(f"{name[:48]:48s}{cells}")
    for p in mods.problems(ac):
        print("⚠", p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
