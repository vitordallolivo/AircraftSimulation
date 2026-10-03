"""Características estáticas e calibração do piloto automático.

O piloto usa um modelo interno C_L = CL0 + CLa α. Para qualquer aeronave nova, os dois
são ajustados pela polar do próprio núcleo (−2° a 8°), e o acelerador de equilíbrio
(Dtrim) pela trimagem em voo nivelado na velocidade de cruzeiro.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import ISimBackend, TrimKind
from aerosim.model.aircraft import Aircraft
from aerosim.model.universal import build_model

G0 = 9.80665


def static_characteristics(backend: ISimBackend, ac: Aircraft, V: float = 12.0) -> dict:
    with backend.session_for(build_model(ac)) as s:
        al = np.radians(np.arange(-6.0, 30.01, 0.25))
        rows = [s.aero_coeffs(V, a) for a in al]
        CL = np.array([r["CL"] for r in rows])
        Cm = np.array([r["Cm"] for r in rows])
        mp = s.mass_props()
    sel = (al >= math.radians(-2)) & (al <= math.radians(8))
    CLa, CL0 = np.polyfit(al[sel], CL[sel], 1)
    dCm = np.polyfit(CL[sel], Cm[sel], 1)[0]
    i = int(np.argmax(CL))
    S, c, b = ac.references()
    CLmax = float(CL[i])
    Vs = math.sqrt(2 * mp["m"] * G0 / (ac.environment.rho * S * CLmax)) if CLmax > 0 else float("nan")
    return dict(CL0=float(CL0), CLa=float(CLa), CLmax=CLmax, alpha_stall=math.degrees(al[i]),
                static_margin=float(-dCm), x_np=float(mp["cg"][0] - dCm * c), Vs=Vs, mass=mp["m"],
                cg=list(mp["cg"]), Sref=S, cref=c, bref=b)


def calibrate(backend: ISimBackend, ac: Aircraft) -> dict:
    """ajusta ac.autopilot (CL0, CLa, Dtrim) e devolve as características estáticas"""
    info = static_characteristics(backend, ac)
    if not ac.autopilot.auto_calibrate:
        return info
    ac.autopilot.CL0 = info["CL0"]
    ac.autopilot.CLa = info["CLa"]
    Vc = max((sg["V1"] for sg in ac.mission.segments()), default=15.0)
    with backend.session_for(build_model(ac)) as s:
        tp = s.trim(TrimKind.LEVEL, Vc)
    if tp["ok"] and 0.05 < tp["thr"] < 1.0:
        ac.autopilot.Dtrim = float(tp["thr"])
    info["Dtrim"] = ac.autopilot.Dtrim
    return info
