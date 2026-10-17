"""Validação contra um avião real: o Ryan Navion (monomotor a pistão, anos 1940) montado com os números publicados e as
derivadas de estabilidade e controle de cada método do programa comparadas com as tiradas do voo.

Fonte única dos números (o PDF não fica no repositório; regra 7 do .claude/CLAUDE.md):
    Suit, W. T., "Aerodynamic Parameters of the Navion Airplane Extracted From Flight Data", NASA TN D-6643, 1972.
    Tabela I (dimensões, massa, inércias, comandos), Tabela II (condições de voo), Figura 2 (vista em três planos),
    Tabelas VII e XI (derivadas tiradas do voo).

Cada número do modelo diz de onde veio:
    [T1]   Tabela I            [T2] Tabela II            [F2] cota escrita na Figura 2
    [F2m]  medido no desenho da Figura 2 (escala pelas cotas 8,35 m e 10,20 m; uns ±5 %)
    [geo]  geometria do trapézio (área, alongamento e afilamento da Tabela I)
    [est]  estimado, sem fonte no relatório (dito no comentário)

    python tools/validacao/navion.py                  # tabela no terminal, condição I (73,2 m/s, flape 0)
    python tools/validacao/navion.py --png navion.png # e o gráfico
"""
from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

FT = 0.3048

# ---------------------------------------------------------------------- dados do relatório
WING = dict(S=17.112, AR=6.04, taper=0.54, sweep_le=2.996, dihedral=7.5, inc_root=2.0, inc_tip=-1.0,   # [T1]
            foil_root="4415", foil_tip="6410")                                                       # [T1]
HTAIL = dict(S=4.0, AR=4.0, taper=0.67, sweep_le=6.0, foil="0012")                                   # [T1]
HTAIL_INC = -5.0          # [F2] legenda: "it ... was set at -5° for these tests" (a Tabela I diz -3)
VTAIL_S = 1.163           # [T1] área acima da EH
MASS, CG_MAC = 1335.76, 0.25                                                                          # [T1]
INERTIA = dict(Ixx=1742.33, Iyy=3762.4, Izz=4389.10)                                                  # [T1]
# condições de voo [T2]: altitude 1,525 km (ρ da ISA)
CONDITIONS = {"I": dict(V=73.2, flap=0.0, CL=0.271), "II": dict(V=43.9, flap=20.0, CL=0.753)}
ALTITUDE = 1525.0

# derivadas tiradas do voo, por rad; arfagem por q c/2V, laterais por p b/2V e r b/2V, eixos do corpo no CG.
# Longitudinais: Tabela VII; C_Zα e C_Zq viram C_Lα ≈ −C_Zα e C_Lq ≈ −C_Zq (α pequeno). Laterais: Tabela XI.
FLIGHT = {
    "I": {"CLa": 4.33, "Cma": -0.77, "Cmq": -18.1, "CLq": 15.9, "CLde": 0.511, "Cmde": -1.42,
          "CYb": -0.6, "Clb": -0.07, "Clp": -0.49, "Clr": 0.11, "Clda": 0.154, "Cldr": 0.026,
          "Cnb": 0.073, "Cnp": -0.04, "Cnr": -0.09, "Cnda": -0.004, "CYdr": 0.33, "Cndr": -0.063},
    "II": {"CLa": 4.86, "Cma": -0.84, "Cmq": -16.4, "CLq": 27.13, "CLde": 0.52, "Cmde": -1.55,
           "CYb": -0.74, "Clb": -0.053, "Clp": -0.53, "Clr": 0.114, "Clda": 0.16, "Cldr": 0.0007,
           "Cnb": 0.083, "Cnp": -0.147, "Cnr": -0.108, "Cnda": -0.0015, "CYdr": 0.68, "Cndr": -0.067},
}
# o relatório também dá C_mα̇ (−6,5 e −6,0) e C_mq + C_mα̇ (−24,6 e −22,4); o programa não tem C_mα̇
FLIGHT_NOTES = "C_mq do voo sem o C_mα̇ (o programa é quase estacionário: não tem C_mα̇)"


def isa_rho(h: float) -> float:
    """densidade da atmosfera padrão na troposfera (ISA): ρ = 1,225 (1 − 2,25577e-5 h)^4,2559"""
    return 1.225 * (1.0 - 2.25577e-5 * h) ** 4.2559


def _trapezoid(S, AR, taper):
    """envergadura, corda na raiz e na ponta, CMA e a posição dela ao longo da semienvergadura [geo]"""
    b = math.sqrt(AR * S)
    cr = 2 * S / (b * (1 + taper))
    mac = 2 / 3 * cr * (1 + taper + taper ** 2) / (1 + taper)
    y_mac = b / 6 * (1 + 2 * taper) / (1 + taper)
    return b, cr, cr * taper, mac, y_mac


def aircraft(condition: str = "I"):
    """o Navion como `Aircraft`, origem no CG (25 % da CMA), x à frente, z para baixo"""
    from aerosim.model.aircraft import (Aircraft, ControlSurface, Fuselage, LiftingSurface, MassModel,
                                        WingSection)
    from aerosim.model.airfoil import Airfoil, naca4

    def foil(code):
        # inclinação, c_l máx e c_d0: os padrões do programa [est], o relatório não dá; α0 e c_m da linha média
        return Airfoil(name=f"NACA {code}", coords=naca4(code).tolist())

    # ---- asa
    b, cr, ct, mac, y_mac = _trapezoid(WING["S"], WING["AR"], WING["taper"])
    semi = b / 2
    x_tip = math.tan(math.radians(WING["sweep_le"])) * semi                     # recuo do bordo de ataque na ponta
    x_mac_le = math.tan(math.radians(WING["sweep_le"])) * y_mac
    x_root = CG_MAC * mac + x_mac_le                                             # CG a 25 % da CMA [T1]
    twist = WING["inc_tip"] - WING["inc_root"]
    flap = CONDITIONS[condition]["flap"]
    wing = LiftingSurface(
        name="asa", role="wing", x=x_root, z=0.30,          # [F2m] asa baixa: 1/4 de corda ~0,3 m abaixo do CG
        sections=[WingSection(0.0, cr, 0.0, 0.0, foil(WING["foil_root"])),
                  WingSection(semi, ct, x_tip, twist, foil(WING["foil_tip"]))],
        dihedral=WING["dihedral"], incidence=WING["inc_root"], airfoil=foil(WING["foil_root"]),
        # [F2m] aileron de 65 % a 96 % da semienvergadura; flape (simples) da fuselagem até o aileron; corda dos dois
        # ~25 % [F2m]; efetividade pelo perfil fino (padrão do programa)
        controls=[ControlSurface("aileron", 0.65, 0.96, 0.25),
                  ControlSurface("flap", 0.12, 0.65, 0.25, deflection=flap)])
    # ---- empenagem horizontal
    bh, crh, cth, mach, y_mach = _trapezoid(HTAIL["S"], HTAIL["AR"], HTAIL["taper"])
    lt = 4.7                                                # [F2m] 1/4 da CMA da EH atrás do CG
    xh_mac_le = math.tan(math.radians(HTAIL["sweep_le"])) * y_mach
    htail = LiftingSurface(
        name="EH", role="htail", x=-lt + 0.25 * mach + xh_mac_le, z=0.0,          # [F2m] na altura do CG
        sections=[WingSection(0.0, crh, 0.0, 0.0),
                  WingSection(bh / 2, cth, math.tan(math.radians(HTAIL["sweep_le"])) * bh / 2, 0.0)],
        incidence=HTAIL_INC, airfoil=foil(HTAIL["foil"]), downwash=True,
        controls=[ControlSurface("elevator", 0.0, 1.0, 1.31 / (1.31 + 2.79))])  # [T1] corda = área do profundor
    # ---- empenagem vertical: área [T1]; altura 1,37 m, raiz 1,0 m, ponta 0,7 m, enflechamento 24° [F2m]
    hv, cvr, cvt = 1.37, 1.0, 0.7
    vtail = LiftingSurface(
        name="EV", role="vtail", x=-4.83, z=0.0, symmetric=False, vertical=True,     # [F2m]
        sections=[WingSection(0.0, cvr, 0.0, 0.0), WingSection(hv, cvt, math.tan(math.radians(24.0)) * hv, 0.0)],
        airfoil=foil("0012"),                                                     # [T1] 0013,2 a 0012,04
        controls=[ControlSurface("rudder", 0.0, 1.0, 0.558 / VTAIL_S)])           # [T1] corda = área do leme
    ac = Aircraft(
        name="Ryan Navion (NASA TN D-6643)",
        surfaces=[wing, htail, vtail],
        # [F2] nariz 2,44 m à frente do CG, comprimento 8,35 m; largura 1,24 m e altura 1,4 m [F2m]. Sem fonte para
        # as derivadas da fuselagem: ficam zero (o programa não estima a fuselagem) [est]
        fuselage=Fuselage(x_nose=8.00 * FT, length=8.35, width=1.24, height=1.4, z=0.0, CDS=0.0, Cma=0.0,
                          Cnb=0.0, CYb=0.0),
        propulsion=[],                       # só a aerodinâmica: as derivadas do voo são da célula
        mass=MassModel(base_mass=MASS, base_cg=[0.0, 0.0, 0.0], Ixz=0.0, **INERTIA),   # [T1]; I_xz = 0 (ref. 8 dele)
    )
    ac.environment.rho = isa_rho(ALTITUDE)
    ac.Sref, ac.cref, ac.bref = WING["S"], mac, b
    return ac


def compare(backend, condition: str = "I", solvers=None) -> list[dict]:
    """as derivadas de cada método do programa no α do C_L da condição de voo, contra as do voo"""
    import numpy as np
    from aerosim.aero import all_solvers
    from aerosim.interfaces.aero import AeroCase
    from aerosim.model.universal import build_model
    cond = CONDITIONS[condition]
    ac = aircraft(condition)
    model = build_model(ac)
    rho = ac.environment.rho
    out = []
    for so in solvers or all_solvers(backend):
        if so.available() or so.name == "asb_ll":     # LiftingLine do ASB: sem taxas
            continue
        # o α do voo: onde o C_L do método vale o da condição (o mesmo C_L, como no relatório)
        pol = so.solve(model, AeroCase(V=cond["V"], rho=rho, alpha_d=2.0, alphas=np.arange(-4.0, 10.01, 1.0)))
        a_cl = float(np.interp(cond["CL"], pol.CL, pol.alpha))
        pol = so.solve(model, AeroCase(V=cond["V"], rho=rho, alpha_d=a_cl, alphas=np.array([a_cl])))
        out.append(dict(solver=so.title, alpha=a_cl, derivs=pol.derivs))
    return out


def table(rows: list[dict], condition: str = "I") -> str:
    fl = FLIGHT[condition]
    keys = list(fl)
    head = f"{'derivada':8s} {'voo':>8s} " + " ".join(f"{r['solver'][:18]:>18s}" for r in rows)
    lines = [head]
    for k in keys:
        cells = []
        for r in rows:
            v = r["derivs"].get(k, float("nan"))
            err = 100 * (v - fl[k]) / abs(fl[k]) if fl[k] else float("nan")
            cells.append(f"{v:9.3f} ({err:+5.0f}%)" if math.isfinite(v) else f"{'—':>18s}")
        lines.append(f"{k:8s} {fl[k]:8.3f} " + " ".join(f"{c:>18s}" for c in cells))
    lines.append("α do C_L da condição: " + ", ".join(f"{r['solver']}: {r['alpha']:.2f}°" for r in rows))
    lines.append(FLIGHT_NOTES)
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--condicao", default="I", choices=tuple(CONDITIONS))
    ap.add_argument("--png", help="grava o gráfico (erro de cada derivada por método)")
    args = ap.parse_args(argv)
    from aerosim.backend.zig import ZigBackend
    rows = compare(ZigBackend(), args.condicao)
    print(table(rows, args.condicao))
    if args.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
        fl = FLIGHT[args.condicao]
        keys = list(fl)
        fig, ax = plt.subplots(figsize=(13, 4.6))
        w = 0.8 / max(len(rows), 1)
        for i, r in enumerate(rows):
            err = [100 * (r["derivs"].get(k, np.nan) - fl[k]) / abs(fl[k]) for k in keys]
            ax.bar(np.arange(len(keys)) + (i - (len(rows) - 1) / 2) * w, np.clip(err, -200, 200), w, label=r["solver"])
        ax.axhline(0, color="k", lw=0.8)
        ax.axhspan(-20, 20, color="#2ca02c", alpha=0.08, label="±20 %")
        ax.set_xticks(np.arange(len(keys)), keys)
        ax.set_ylabel("erro contra o voo (%)")
        ax.set_title(f"Navion, condição {args.condicao}: derivadas de cada método × voo (NASA TN D-6643)")
        ax.grid(axis="y", alpha=0.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(args.png, dpi=110)
        print(f"gráfico em {args.png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
