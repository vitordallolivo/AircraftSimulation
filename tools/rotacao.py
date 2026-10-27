"""O comando de arfagem roda o avião na pista? A conta da sprint contra a do núcleo, termo a termo.

    python tools/rotacao.py "asa voadora"                                   # o avião da categoria no exemplo
    python tools/rotacao.py "asa voadora" tail.aileron_chord=0.48 rules.de_max=25 --png perfis/rotacao.png
    python tools/rotacao.py monoplano --varre rules.main_gear_aft=0:0.1:6   # V_rot pelas duas contas, varrendo

O avião é o do projeto de exemplo do aeroopt, montado pela sprint com a categoria e os valores dados. A sprint
(`power.thrust_trim`) e o núcleo (`aeroopt.stages.core_rotation`) somam os mesmos momentos no trem principal
(+ cabra), com o comando todo cabrando e o avião no chão:

    M(V) = q S c C_m,CG + q S C_L (x_CG − x_TP) + M_tração(V) − W (x_CG − x_TP)

A diferença é de onde vêm C_m e C_L: a conta analítica da sprint ou os coeficientes do núcleo (o modelo do 6GDL).
A ferramenta imprime V_rot das duas, a velocidade de sair do chão, cada termo na velocidade de sair do chão e o
C_mδ das duas; `--png` desenha M(V) e C_m(δ) do núcleo (um C_m que não cresce com o curso aparece ali).
"""
import argparse
import math
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)

import numpy as np  # noqa: E402

from aeroopt import stages as sg  # noqa: E402
from aeroopt.gui import example_project  # noqa: E402
from aerosim.backend.zig import ZigBackend  # noqa: E402
from aerosim.design import power as pw  # noqa: E402
from aerosim.model.universal import build_model  # noqa: E402


def _value(s: str):
    try:
        return float(s)
    except ValueError:
        return s


def analyze(project, values: dict, backend) -> dict:
    """V_rot pela sprint e pelo núcleo, os termos de M na velocidade de sair do chão e C_m(δ) do núcleo"""
    q, cand = sg.candidate(project, values)
    ac, asm = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
    tr = asm.get("trim") or {}
    core = sg.core_rotation(ac, asm, q.rules, q.requirements.rho, backend)
    out = dict(values=values, V_lof=tr.get("V_lof", math.nan), V_sprint=tr.get("V_rot", math.nan),
               V_core=(core or {}).get("V_rot", math.nan), Cmde_sprint=asm["set"].get("Cmde", math.nan))
    if core is None:
        return out
    model = build_model(ac)
    us = [u for u in ac.propulsion if u.enabled]
    Vg, M_core, arm = core["rot_table"]
    _, M_sprint, _ = tr["rot_table"]
    W = float(asm["mass"]) * pw.G0
    out.update(V=Vg, M_core=M_core - W * arm, M_sprint=M_sprint - W * arm)
    de_max = math.radians(q.rules.de_max)
    des = np.radians(np.linspace(-40.0, 0.0, 17))
    with backend.session_for(model) as s:
        k = s.aero_coeffs(10.0, 0.0, de=-de_max)
        cm = np.array([s.aero_coeffs(10.0, 0.0, de=float(d))["Cm"] for d in des])
        k0 = s.aero_coeffs(10.0, 0.0, de=0.0)
    out.update(de=np.degrees(des), Cm_de=cm, Cmde_core=(k0["Cm"] - k["Cm"]) / de_max)
    V = out["V_lof"]
    qS = 0.5 * q.requirements.rho * V * V * model.S
    T = float(pw.thrust_of(ac, np.array([V]), q.requirements.rho, None)[0]) / len(us)
    out["terms"] = {"q S c C_m": qS * model.c * k["Cm"], "q S C_L braço": qS * k["CL"] * arm,
                    "tração": pw._thrust_moment(us, T, ac.gear.main_x, ac.gear.main_z), "peso": -W * arm}
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("categoria", help="categoria do aeroopt: monoplano, biplano, tandem, asa voadora")
    ap.add_argument("valores", nargs="*", help="chave=valor do aeroopt (ex.: rules.de_max=25)")
    ap.add_argument("--varre", help="chave=início:fim:pontos, V_rot pelas duas contas em cada ponto")
    ap.add_argument("--png", help="grava M(V) e C_m(δ) do núcleo (ou a varredura)")
    a = ap.parse_args(argv)
    project, _ = example_project()
    values = {"categoria": a.categoria, **{k: _value(v) for k, v in (s.split("=", 1) for s in a.valores)}}
    be = ZigBackend()
    if a.varre:
        key, rng = a.varre.split("=", 1)
        lo, hi, n = rng.split(":")
        xs = np.linspace(float(lo), float(hi), int(n))
        rows = [analyze(project, {**values, key: float(x)}, be) for x in xs]
        print(f"{key:>22} {'V_rot sprint':>13} {'V_rot núcleo':>13} {'V_lof':>7}  (m/s)")
        for x, r in zip(xs, rows):
            print(f"{x:22.4g} {r['V_sprint']:13.2f} {r['V_core']:13.2f} {r['V_lof']:7.2f}")
        if a.png:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(figsize=(7, 4))
            for k, lab, c in (("V_sprint", "V_rot sprint", "#e34948"), ("V_core", "V_rot núcleo", "#2a78d6"),
                              ("V_lof", "sai do chão", "#52514e")):
                ax.plot(xs, [min(r[k], 40.0) for r in rows], "o-", color=c, label=lab)
            ax.set_xlabel(key)
            ax.set_ylabel("V (m/s); 40 = não roda")
            ax.legend(frameon=False)
            ax.grid(color="#e4e3df")
            fig.tight_layout()
            fig.savefig(a.png, dpi=125)
        return 0
    r = analyze(project, values, be)
    print(f"V_rot: sprint {r['V_sprint']:.2f} m/s, núcleo {r['V_core']:.2f} m/s; sai do chão a {r['V_lof']:.2f} m/s")
    if "terms" not in r:
        print("sem corrida para conferir (sem motor ou sem triciclo)")
        return 0
    print(f"C_mδ: sprint {r['Cmde_sprint']:.3f} /rad, núcleo {r['Cmde_core']:.3f} /rad")
    print(f"momentos no trem principal a {r['V_lof']:.2f} m/s (N·m, + cabra):")
    for k, v in r["terms"].items():
        print(f"  {k:>14} {v:+8.3f}")
    print(f"  {'soma':>14} {sum(r['terms'].values()):+8.3f}")
    if a.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, (ax, bx) = plt.subplots(1, 2, figsize=(11, 4))
        ax.plot(r["V"], r["M_sprint"], color="#e34948", label="sprint")
        ax.plot(r["V"], r["M_core"], color="#2a78d6", label="núcleo")
        ax.axhline(0, color="#b0b0b0", lw=1)
        ax.axvline(r["V_lof"], color="#52514e", ls="--", label="sai do chão")
        ax.set_xlabel("V (m/s)")
        ax.set_ylabel("M no trem principal (N·m, + cabra)")
        ax.legend(frameon=False)
        bx.plot(r["de"], r["Cm_de"], "o-", color="#2a78d6")
        bx.set_xlabel("δ (°, − cabra)")
        bx.set_ylabel("C_m no CG do núcleo (α = 0)")
        for x in (ax, bx):
            x.grid(color="#e4e3df")
        fig.tight_layout()
        fig.savefig(a.png, dpi=125)
    return 0


if __name__ == "__main__":
    sys.exit(main())
