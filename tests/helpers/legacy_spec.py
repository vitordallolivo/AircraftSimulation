"""Converte a aeronave do código original (legacy/py/aeronave.py) direto para SimSpec,
campo a campo, para comparar o núcleo Zig com o simulador em C."""
import math
import os
import sys

LEGACY_PY = os.path.join(os.path.dirname(__file__), "..", "..", "legacy", "py")
D2R = math.pi / 180


def legacy_modules():
    sys.path.insert(0, os.path.abspath(LEGACY_PY))
    import aeronave
    import percurso
    import simulador
    return aeronave, percurso, simulador


def spec_from_legacy(av: dict, perc: dict) -> dict:
    e = av["escalares"]
    surf = []
    for s in av["superficies"]:
        ctrl = s.get("ctrl", 0)
        mix = [0.0, 0.0, 0.0]
        if ctrl:
            mix[{2: 0, 1: 1, 3: 2}[ctrl]] = float(s.get("sinal", 1))
        surf.append(dict(
            r=[s.get("x", 0), s.get("y", 0), s.get("z", 0)], S=s["S"], c=s["c"], AR=s.get("AR", 5), e=s.get("e", 0.8),
            dihedral=s.get("diedro", 0) * D2R, incidence=s.get("incid", 0) * D2R, CLa=s.get("CLa", 4.5),
            CL0=s.get("CL0", 0), CLmax=s.get("CLmax", 1.2), CD0=s.get("CD0", 0.01), Cmac=s.get("Cmac", 0),
            tau=s.get("tau", 0), mix=mix, eta=s.get("eta", 1), eps0=s.get("eps0", 0) * D2R,
            depsda=s.get("depsda", 0), group=s.get("grupo", 0), vertical=s.get("vertical", 0),
            side=s.get("lado", 0), downwash=s.get("downwash", 0)))
    hel = av["helice"]
    prop = [dict(r=list(e["rp"]), tilt=e["phiT"] * D2R, toe=e["psiT"] * D2R, sense=e["sentido"], D=e["D"], Ip=e["Ip"],
                 Jm=e["Jm"], Kv=e["Kv"], Rm=e["Rm"], B=e["B"], tauc=e["tauc"], Imax=e["Imax"], Voc=e["Voc"],
                 Rint=e["Rint"], J=[h[0] for h in hel], CT=[h[1] for h in hel], CP=[h[2] for h in hel])]
    gear = [dict(r=[c["x"], c["y"], c["z"]], k=c["k"], c=c["c"], kind=c["tipo"]) for c in av["contatos"]]
    ap_keys = dict(CL0="ap_CL0", CLa="ap_CLa", alpha_max="alfa_max", g_up="g_sobe", g_down="g_desce")
    ap = {}
    for k in ("Khr", "Kvs", "Kn_h", "Kn_hd", "Kn_ih", "Kae", "KIa", "Kfn", "Lorb", "tlead", "Kthe", "Kqe", "KV",
              "KIV", "KHT", "Dtrim", "Kchi", "kvf", "korb", "Kphia", "Kpa", "Kbeta", "tau_phi", "Ky", "Ki", "Kpsi",
              "Kr", "Kbeq", "hflare", "tau_flare", "kCL"):
        ap[k] = e[k]
    for k, lk in ap_keys.items():
        ap[k] = e[lk] * (D2R if k == "alpha_max" else 1)
    ap.update(chi_inf=e["chi_inf"] * D2R, phimax=e["phimax"] * D2R, pmax_cmd=e["pmax_cmd"] * D2R)
    segs = []
    for s in perc["segmentos"]:
        segs.append(dict(arc=s.get("arco", 0), takeoff=s.get("decolagem", 0), landing=s.get("pouso", 0),
                         n0=s.get("n0", 0), e0=s.get("e0", 0), chi0=s.get("chi0", 0) * D2R, L=s.get("L", 0),
                         cn=s.get("cn", 0), ce=s.get("ce", 0), R=s.get("R", 0), lam=s.get("lam", 1),
                         h0=s["h0"], h1=s["h1"], V0=s["V0"], V1=s["V1"], clearance=s.get("folga", 0)))
    events = [dict(kind=0 if ev["tipo"] == "lapes" else 1, seg=ev["seg"], s=ev["s"]) for ev in perc["eventos"]]
    return dict(
        m_dry=e["m_seca"], Ixx=e["Ixx"], Iyy=e["Iyy"], Izz=e["Izz"], Ixz=e["Ixz"], r_dry=list(e["r_seca"]),
        Sref=e["Sref"], cref=e["cref"], bref=e["bref"], Mst=e["Mst"], fus_CDS=e["fus_CDS"], fus_Cma=e["fus_Cma"],
        fus_Cnb=e["fus_Cnb"], fus_CYb=e["fus_CYb"], fus_r=list(e["fus_r"]), surf=surf, prop=prop, gear=gear,
        tank=[dict(r=list(e["rt"]), shape=1, side=2 * e["Rtq"], fill=e["htq"], rho=e["rho_liq"], zeta=e["zeta_s"])],
        slosh_on=e["slosh"], mu_roll=e["mu_r"], mu_lat=e["mu_lat"], mu_brake=e["mu_freio"], mu_skid=e["mu_cauda"],
        mu_landing=e["mu_pouso"],
        payload=dict(enabled=1, m=e["mL"], r=list(e["rL"]), bay=e["baia"], Fext_g=e["Fext_g"], mu_b=e["mu_b"],
                     CdS_chute=e["CdS_par"]),
        env=dict(rho=e["rho"], Vw10=e["Vw10"], wind_from=e["psiw"] * D2R, wind_elev=e["chiw"] * D2R,
                 h_ref=e["hw_ref"], gust_T=e["Tg"], gust_U=list(e["Ug"]), gust_on=e["rajada"]),
        takeoff=dict(VR=e["VR"], sR=e["sR"], de0=e["de0"] * D2R, de1=e["de1"] * D2R, rate_de=e["taxa_de"] * D2R,
                     ht=e["ht"], rate_thr=e["taxa_acel"], h_end=e["h_fim_dec"]),
        ap=ap, dt=e["dt"], tmax=e["tmax"], dtlog=e["dtlog"], seg=segs, event=events)
