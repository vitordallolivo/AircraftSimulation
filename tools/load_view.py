"""Vista 3D da carga aerodinâmica de um avião num ponto de operação: as superfícies pintadas pela carga alar local
(ou α efetivo, velocidade local, c_l...), setas de força e de velocidade induzida e a esteira. Abre uma janela ou, com
--png, grava a imagem. Usa aerosim/aero/span_loads.py (conta do núcleo) e a entrada padrão aerosim/interfaces/loads.py.

    python tools/load_view.py data/aircraft/Convencional_original.json                     # nivelado a 12 m/s
    python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco --campo alpha_ef
    python tools/load_view.py meu_aviao.json --V 15 --n 2 --png carga.png --azimute -60 --elevacao 35
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("aviao")
    ap.add_argument("--V", type=float, default=12.0, help="velocidade do ar (m/s); padrão 12")
    ap.add_argument("--n", type=float, default=1.0, help="fator de carga da trimagem")
    ap.add_argument("--alpha", type=float, default=None, help="α do corpo (°); sem ele: trimagem")
    ap.add_argument("--rpm", type=float, action="append", help="rotação (rpm): uma para todos ou uma por motor")
    ap.add_argument("--com", action="append", default=[], help="modificador a ligar (ex.: esteira.disco)")
    ap.add_argument("--campo", default="carga", help="carga | L | alpha_ef | V_rel | cl | cd | q | D")
    ap.add_argument("--sem-forcas", action="store_true")
    ap.add_argument("--induzida", action="store_true", help="mostra as setas de velocidade induzida")
    ap.add_argument("--png", help="grava a imagem aqui (não abre janela)")
    ap.add_argument("--azimute", type=float, default=-125)
    ap.add_argument("--elevacao", type=float, default=28)
    ap.add_argument("--distancia", type=float, default=None)
    args = ap.parse_args(argv)
    from PyQt6 import QtWidgets

    from aerosim.aero.span_loads import LoadCase, compute, to_result
    from aerosim.backend.zig import ZigBackend
    from aerosim.data import load_aircraft
    from aerosim.gui.widgets.load_view import LoadView
    from aerosim.model import modifiers as mods
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)
    be = ZigBackend()
    ac = load_aircraft(args.aviao)
    ac.modifiers += [mods.Modifier(k) for k in args.com]
    rpm = None if not args.rpm else (args.rpm[0] if len(args.rpm) == 1 else args.rpm)
    res = to_result(compute(be, ac, LoadCase(V=args.V, n=args.n, alpha=args.alpha, rpm=rpm)), be)
    w = LoadView()
    w.field = args.campo
    w.show_force.setChecked(not args.sem_forcas)
    w.show_ind.setChecked(args.induzida)
    w.set_result(res, ac)
    size = max(float(abs(res.field.vertices).max()) * 2.6, 2.0)
    w.set_camera(distance=args.distancia or size, elevation=args.elevacao, azimuth=args.azimute)
    w.resize(1200, 900)
    w.setWindowTitle(f"carga — {os.path.basename(args.aviao)}")
    w.show()
    app.processEvents()
    if args.png:
        w.save_png(args.png)
        print(args.png)
        return 0
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
