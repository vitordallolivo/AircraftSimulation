"""Carga ao longo das superfícies (asa, EH, EV) num ponto de operação — velocidade, α e rotação dos motores — com e
sem um modificador (ex.: a esteira). Usa o módulo aerosim/aero/span_loads.py (a conta é do núcleo).

    python tools/span_load.py data/aircraft/Convencional_original.json --png carga.png         # nivelado a 12 m/s
    python tools/span_load.py data/aircraft/Convencional_original.json --V 15 --n 2 --com esteira.disco --png curva.png
    python tools/span_load.py data/aircraft/Convencional_original.json --V 8 --alpha 2 --rpm 6000 --com esteira.disco
    python tools/span_load.py meu_aviao.json --V 10 --alpha 4 --acelerador 0.8 --com esteira.disco --csv carga.csv
    python tools/span_load.py bimotor.json --rpm 6000 --rpm 6500                  # uma rotação por motor
"""
from __future__ import annotations

import argparse
import copy
import csv
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("aviao")
    ap.add_argument("--com", action="append", default=[], help="modificador comparado (tipo, ex.: esteira.disco)")
    ap.add_argument("--V", type=float, default=12.0, help="velocidade do ar (m/s); padrão 12")
    ap.add_argument("--alpha", type=float, default=None, help="α do corpo (°); sem ele: o do voo nivelado na V (trimagem)")
    ap.add_argument("--n", type=float, default=1.0, help="fator de carga da trimagem (1 nivelado; > 1 curva)")
    ap.add_argument("--beta", type=float, default=0.0, help="β (°)")
    ap.add_argument("--rpm", type=float, action="append", help="rotação (rpm): uma para todos ou uma por motor")
    ap.add_argument("--acelerador", type=float, default=1.0, help="sem --rpm: rotação de equilíbrio com este acelerador")
    ap.add_argument("--csv")
    ap.add_argument("--png")
    args = ap.parse_args(argv)
    from aerosim.aero.span_loads import LoadCase, compute
    from aerosim.backend.zig import ZigBackend
    from aerosim.data import load_aircraft
    from aerosim.model import modifiers as mods
    be = ZigBackend()
    base = load_aircraft(args.aviao)
    rpm = None if not args.rpm else (args.rpm[0] if len(args.rpm) == 1 else args.rpm)
    case = LoadCase(V=args.V, alpha=args.alpha, n=args.n, beta=args.beta, rpm=rpm, throttle=args.acelerador)
    runs = [("sem " + "+".join(args.com) if args.com else "como está", base)]
    if args.com:
        ac = copy.deepcopy(base)
        ac.modifiers += [mods.Modifier(k) for k in args.com]
        runs.append(("com " + "+".join(args.com), ac))
    res = [(lab, compute(be, ac, case)) for lab, ac in runs]
    props = res[0][1].props
    r0 = res[0][1]
    how = "trimagem" if r0.trim is not None else "imposto"
    print(f"V = {args.V:g} m/s, n = {args.n:g}: α = {r0.alpha:.2f}° ({how}), δe = {r0.de:.2f}°, peso = {r0.weight:.1f} N")
    for note in r0.notes:
        print("⚠", note)
    print("motores: " + "; ".join(f"{p.name}: {p.rpm:.0f} rpm, T = {p.T:.2f} N, Q = {p.Q:.3f} N·m, J = {p.J:.3f}"
                                  for p in props))
    rows = []
    for lab, r in res:
        for s in r.surfaces:
            print(f"{lab:22s} {s.name:18s} sustentação = {s.lift:8.2f} N   arrasto = {s.drag:7.3f} N")
            rows += [[lab, s.name, s.role, x, l, d, a, v] for x, l, d, a, v in zip(s.s, s.L, s.D, s.alpha, s.V)]
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["caso", "superficie", "papel", "s_m", "sustentacao_N_por_m", "arrasto_N_por_m", "alpha_local_graus",
                        "V_local_m_s"])
            w.writerows(rows)
    if args.png:
        from aerosim.aero.load_plots import span_figure
        from aerosim.aero.span_loads import to_result
        mot = ", ".join(f"{p.rpm:.0f} rpm / {p.T:.1f} N" for p in props)
        title = (f"{os.path.basename(args.aviao)} — V = {args.V:g} m/s, n = {args.n:g}, α = {r0.alpha:.2f}° ({how}), "
                 f"δe = {r0.de:.1f}°, peso {r0.weight:.1f} N; motores: {mot}; cinza = disco da hélice")
        fig = span_figure([(lab, to_result(r)) for lab, r in res], fields=("carga", "L", "alpha_ef", "V_rel"),
                          shade=[(p.hub[1] - p.D / 2, p.hub[1] + p.D / 2) for p in props], title=title)
        fig.savefig(args.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
