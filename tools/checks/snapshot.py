"""Retrato numérico dos aviões de exemplo, para comparar duas versões do código bit a bit.

Roda dentro da árvore que se quer retratar (a atual ou uma cópia de outro commit). Por isso usa só a API pública que
existe há tempo e tolera o que faltar: cada parte que não existir naquela versão vira "indisponível" e não quebra o
resto.

    python tools/checks/snapshot.py --raiz <árvore> --saida retrato.pkl [--rapido]

Para cada arquivo de `data/aircraft` (.json/.cfg):
    coef      coeficientes aerodinâmicos do núcleo em V × α × β
    trim      trimagem nivelada em algumas velocidades
    decolagem resumo numérico + log completo da missão "só decolagem" (sem --rapido)
"""
from __future__ import annotations

import argparse
import math
import os
import pickle
import sys
import traceback


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raiz", required=True, help="árvore do repositório a retratar")
    ap.add_argument("--saida", required=True)
    ap.add_argument("--rapido", action="store_true", help="sem a decolagem (só coeficientes e trimagem)")
    a = ap.parse_args(argv)
    sys.path.insert(0, a.raiz)
    os.chdir(a.raiz)
    import numpy as np
    from aerosim.backend.zig import ZigBackend
    from aerosim.data import load_aircraft
    from aerosim.model.universal import build_model
    be = ZigBackend()
    man = None
    if not a.rapido:
        from aerosim.manager import SimulationManager
        man = SimulationManager(be)
    try:
        from aerosim.interfaces.backend import TrimKind
    except ImportError:
        TrimKind = None
    out = {}
    folder = os.path.join(a.raiz, "data", "aircraft")
    for f in sorted(os.listdir(folder)):
        if not f.endswith((".json", ".cfg")):
            continue
        r = {}
        try:
            ac = load_aircraft(os.path.join(folder, f))
            model = build_model(ac)
        except Exception:
            out[f] = {"erro": traceback.format_exc(limit=2)}
            continue
        try:
            with be.session_for(model) as s:
                r["coef"] = [s.aero_coeffs(V, math.radians(al), math.radians(b))
                             for V in (10.0, 15.0) for al in (-4, 0, 4, 10, 16) for b in (0, 5)]
                if TrimKind is not None and hasattr(s, "trim"):
                    tr = []
                    for V in (10.0, 13.0, 16.0):
                        try:
                            t = s.trim(TrimKind.LEVEL, V, 1.0)
                            tr.append({k: v for k, v in t.items() if isinstance(v, (int, float, bool))})
                        except Exception as e:
                            tr.append({"erro": repr(e)})
                    r["trim"] = tr
        except Exception:
            r["coef"] = "indisponível: " + traceback.format_exc(limit=1)
        if man is not None:
            try:
                res = man.run("mission", ac, {"mode": "só decolagem"})
                r["resumo"] = {k: v for k, v in res.summary.items() if isinstance(v, (int, float))}
                r["log"] = ({k: np.asarray(v).copy() for k, v in res.log.columns.items()}
                            if res.log is not None else None)
            except Exception:
                r["decolagem"] = "indisponível: " + traceback.format_exc(limit=1)
        out[f] = r
        print(f, flush=True)
    with open(a.saida, "wb") as fh:
        pickle.dump(out, fh)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
