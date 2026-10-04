"""Estudo de teste: asa S1223 (hipersustentador), várias empenagens (MH 113 normal e invertido, HT 14, SD8020,
NACA 0012), três motorizações (monomotor, bimotor, monomotor com motor inclinado) e duas altitudes-densidade
(Joinville e São José dos Campos). Acha o MTOW de cada um de dois jeitos:

    rápido      etapa Motores e montagem (corrida até 1,1 V_S com tração do núcleo)
    6GDL        aba Missão, modo MTOW (bisseção no lastro; decolagem simulada com otimização do profundor)

Grava os projetos da sprint (abrem no menu Projeto da sprint), os aviões (abrem na Montagem e no AeroDrive)
e um relatório em markdown.

    python tools/estudo_s1223.py [pasta]          # padrão: data/sprint
"""
from __future__ import annotations

import copy
import math
import os
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)

from aerosim.backend.zig import ZigBackend                     # noqa: E402
from aerosim.data import save_aircraft                          # noqa: E402
from aerosim.design import airfoils as afm                      # noqa: E402
from aerosim.design import power as pw                          # noqa: E402
from aerosim.design.project import DesignProject                # noqa: E402
from aerosim.manager import SimulationManager                   # noqa: E402
from aerosim.model.atmosphere import density_altitude          # noqa: E402

# ------------------------------------------------------------------ altitude-densidade de cada lugar
R_DRY = 287.05


def ad_of(p_hpa: float, t_c: float, rh: float) -> tuple[float, float]:
    """(ρ, AD) do ar úmido: temperatura virtual com a pressão de vapor de Magnus"""
    T = t_c + 273.15
    e = rh * 6.1094 * math.exp(17.625 * t_c / (t_c + 243.04))
    Tv = T / (1 - 0.378 * e / p_hpa)
    rho = p_hpa * 100 / (R_DRY * Tv)
    return rho, density_altitude(rho)


def station_pressure(qnh: float, elev: float) -> float:
    return qnh * (1 - 2.25577e-5 * elev) ** 5.25588


# condições típicas de tarde quente (editáveis): elevação (m), QNH (hPa), temperatura (°C), umidade relativa
PLACES = {
    "Joinville": dict(elev=4.0, qnh=1013.0, t=30.0, rh=0.75),
    "São José dos Campos": dict(elev=646.0, qnh=1015.0, t=28.0, rh=0.60),
}
AIRFOILS = ("s1223", "mh113", "mh113_invertido", "ht14", "sd8020")
SETS = (  # nome, cauda, perfil da EH, perfil da EV
    ("EH MH 113 inv · EV HT 14", "convencional", "MH 113 invertido", "HT 14"),
    ("EH MH 113 inv · EV SD8020", "convencional", "MH 113 invertido", "SD8020"),
    ("EH MH 113 · EV NACA 0012", "convencional", "MH 113", "NACA 0012"),
    ("EH NACA 0012 · EV NACA 0012", "convencional", "NACA 0012", "NACA 0012"),
    ("cauda em V MH 113 inv", "em V", "MH 113 invertido", "NACA 0012"),
)
POWER = (  # nome, motores, motor, hélice, bateria, inclinação (°)
    ("monomotor", pw.LAYOUTS[0], "Scorpion A-5025-310Kv", "APC 15x8E", "LiPo 6S 5000", 0.0),
    ("bimotor", pw.LAYOUTS[1], "Genérico 500Kv", "Genérica 13x6.5", "LiPo 4S 4000", 0.0),
    ("monomotor inclinado 6°", pw.LAYOUTS[0], "Scorpion A-5025-310Kv", "APC 15x8E", "LiPo 6S 5000", 6.0),
)


def project_for(place: str) -> DesignProject:
    c = PLACES[place]
    rho, ad = ad_of(station_pressure(c["qnh"], c["elev"]), c["t"], c["rh"])
    p = DesignProject()
    p.airfoils = [afm.entry(afm.from_dat(os.path.join(ROOT, "data", "airfoils", f + ".dat"))) for f in AIRFOILS]
    for e in p.airfoils:                  # caminho relativo ao repositório (abre em qualquer máquina)
        e.airfoil.path = os.path.relpath(e.airfoil.path, ROOT)
    rq = p.requirements
    rq.mass, rq.V_cruise, rq.V_stall_max, rq.span_max = 12.0, 13.0, 10.5, 2.5
    rq.density_altitude, rq.takeoff_run, rq.mu_roll = round(ad, 0), 50.0, 0.04
    p.wing_draft.__dict__.update(name="asa S1223", airfoil="S1223", span=2.4, area=0.9, rect_frac=0.5, taper=0.6,
                                 twist=-1.5, dihedral=2.0, alpha_cruise=3.0)
    p.keep_wing()
    for name, lay, eh, ev in SETS:
        p.tail_draft = copy.deepcopy(p.tail_draft)
        p.tail_draft.__dict__.update(name=name, wing="asa S1223", layout=lay, tail_airfoil=eh, vtail_airfoil=ev,
                                     arm=0.95, VH=0.45, VV=0.04, sm_target=12.0)
        p.keep_set()
    for sname, *_ in SETS:
        for pname, lay, mo, pr, bt, tilt in POWER:
            p.power_draft.__dict__.update(name=f"{pname} · {sname}", set=sname, layout=lay, motor=mo, propeller=pr,
                                          battery=bt, tilt=tilt, ballast=2.0, liquid=1.0, lapes=1.0)
            p.keep_aircraft()
    p.tail_draft.name = "conjunto 6"
    p.power_draft.name = "avião novo"
    return p, rho


def mtow_6dof(m, ac, asm) -> float:
    x = asm["x_cg_target"]
    masses = [dict(item="Lastro (kg)", min=0.0, nom=ac.ballast.mass, max=15.0),
              dict(item="xCG (m)", min=x, nom=x, max=x)]
    if ac.payload.enabled:
        masses.insert(1, dict(item="LAPES (kg)", min=ac.payload.mass, nom=ac.payload.mass, max=ac.payload.mass))
    if ac.tanks:
        v = sum(t.volume for t in ac.tanks)
        masses.insert(1, dict(item="Líquido (L)", min=v, nom=v, max=v))
    r = m.run("mission", ac, {"mode": "MTOW (x_warning e z_warning)", "masses": masses})
    return float(r.summary.get("MTOW (kg)", float("nan")))


def _one(job):
    """um avião: monta, desempenho rápido e MTOW 6GDL (roda em processo separado)"""
    place, i = job
    p, rho = project_for(place)
    m = SimulationManager(ZigBackend())
    rq = p.requirements
    cand = p.aircraft[i]
    ac, asm = pw.assemble(cand, rq, p.rules, None, p.airfoil_map())
    pf = pw.performance(ac, asm, rq, m.backend)
    mt6 = mtow_6dof(m, ac, asm)
    st = asm["set"]
    row = dict(place=place, ad=rq.density_altitude, rho=rho, name=cand.name, pv=asm["empty"], cp=asm["payload"],
               mass=asm["mass"], s_to=pf["s_to"], mtow=pf["mtow_runway"], mtow6=mt6, vs=pf["Vs"], ih=st["i_h"],
               ballast_eq=asm["ballast"], vrot=st["V_rot"], vlof=st["V_lof"])
    return row, (ac if cand.set.name == SETS[0][0] else None), cand.params.name


def main(out: str):
    from concurrent.futures import ProcessPoolExecutor
    os.makedirs(os.path.join(out, "avioes"), exist_ok=True)
    t0 = time.time()
    jobs = []
    for place in PLACES:
        p, _ = project_for(place)
        slug = "joinville" if place == "Joinville" else "sjc"
        p.save(os.path.join(out, f"estudo_s1223_{slug}.json"))
        jobs += [(place, i) for i in range(len(p.aircraft))]
    rows = []
    with ProcessPoolExecutor(max_workers=os.cpu_count() or 2) as ex:
        for row, ac, pname in ex.map(_one, jobs):
            rows.append(row)
            if ac is not None:                    # um avião de cada motorização por lugar, para abrir e voar
                slug = "joinville" if row["place"] == "Joinville" else "sjc"
                kind = pname.split(" · ")[0]
                ac.name = f"S1223 {kind} ({row['place']})"
                save_aircraft(ac, os.path.join(out, "avioes",
                                               f"s1223_{kind.replace(' ', '_').replace('°', '')}_{slug}.json"))
            print(f"{row['place']:20s} {row['name']:55s} PV {row['pv']:5.2f}  MTOW rápido {row['mtow']:5.2f}  "
                  f"6GDL {row['mtow6']:5.2f}", flush=True)
    write_report(out, rows, time.time() - t0)


def write_report(out, rows, dt):
    L = ["# Estudo S1223 — MTOW por empenagem, motorização e altitude-densidade", "",
         "Gerado por `python tools/estudo_s1223.py`. Os projetos abrem em **Projeto da sprint → Abrir projeto…**, "
         "os aviões (`avioes/`) em **Arquivo → Abrir arquivo…** ou no AeroDrive.", "",
         "![Motores e montagem: monomotor com EH MH 113 invertido em Joinville](../../docs/img/estudo_motores.png)", "",
         "![Distribuição de massa e MTOW pela pista](../../docs/img/estudo_massas.png)", "",
         "![MTOW 6GDL na aba Missão](../../docs/img/estudo_missao_mtow.png)", "",
         "## Hipóteses", "",
         "- Asa S1223: envergadura 2,4 m, área 0,9 m², 50 % retangular, afilamento 0,6, washout 1,5°, diedro 2°; "
         "ângulo de cruzeiro da fuselagem 3° (com 0° a asa fica calada a ~5,6° e estola na rotação na simulação 6GDL).",
         "- Polares 2D pelo NeuralFoil no Re de cada superfície; empenagem por volume (V_H 0,45, V_V 0,04, braço 0,95 m), "
         "margem estática 12 %.",
         "- Carga paga nominal: lastro 2 kg + líquido 1 L + LAPES 1 kg, no CG. Pista 50 m, z_warning 1 m, μ 0,04.",
         "- MTOW rápido: corrida até 1,1 V_S (motor inclinado: a parte vertical da tração alivia o peso). "
         "MTOW 6GDL: aba Missão, bisseção no lastro (0 a 15 kg), acionamento do profundor otimizado em cada massa "
         "(e, se o avião sai do chão cedo demais, o profundor segurado picando na corrida).",
         "- Rotação: velocidade a partir da qual o profundor todo (20°) levanta o nariz em torno do trem principal, "
         "com o C_L da EH limitado pela polar do perfil nos dois lados — a EH invertida tem c_l negativo maior e roda "
         "antes.",
         "- CP possível = MTOW − PV.", "",
         "| lugar | elevação | QNH | temperatura | umidade | ρ (kg/m³) | AD (m) |", "|---|---|---|---|---|---|---|"]
    seen = {}
    for r in rows:
        seen.setdefault(r["place"], r)
    for place, r in seen.items():
        c = PLACES[place]
        L.append(f"| {place} | {c['elev']:.0f} m | {c['qnh']:.0f} hPa | {c['t']:.0f} °C | {100 * c['rh']:.0f} % | "
                 f"{r['rho']:.3f} | {r['ad']:.0f} |")
    L += ["", "## Resultados", ""]
    for place in seen:
        L += [f"### {place} (AD {seen[place]['ad']:.0f} m)", "",
              "| avião | PV (kg) | i_h (°) | roda a partir de (m/s, sem tração) | sai do chão (m/s) | corrida com CP nominal (m) | "
              "MTOW rápido (kg) | CP possível rápido | MTOW 6GDL (kg) | CP possível 6GDL |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for r in rows:
            if r["place"] != place:
                continue
            f = lambda v: "—" if not math.isfinite(v) else f"{v:.2f}"
            L.append(f"| {r['name']} | {r['pv']:.2f} | {r['ih']:+.1f} | {f(r['vrot'])} | {r['vlof']:.1f} | "
                     f"{r['s_to']:.0f} | {f(r['mtow'])} | "
                     f"{f(r['mtow'] - r['pv'])} | {f(r['mtow6'])} | {f(r['mtow6'] - r['pv'])} |")
        L.append("")
    L.append(f"Tempo total: {dt:.0f} s.")
    with open(os.path.join(out, "estudo_s1223.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "data", "sprint"))
