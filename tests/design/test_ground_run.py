"""Corrida rápida da sprint no núcleo (core/src/sizing/ground.zig): bit a bit igual à conta em Python de antes."""
import math

import numpy as np

from aerosim.design import power as pw
from aerosim.design.project import DesignProject
from aerosim.design.spec import G0


def _python_run(perf_in, mass):
    """a corrida como era em aerosim/design/power.py (performance.run) antes de ir para o núcleo"""
    rho, S, CLg, CD0, K, CLmax, mu, tl, Vg, Tgv, rs = perf_in
    v_rot = rs(mass) if rs else 0.0
    if not math.isfinite(v_rot):
        return float("inf")
    x = v = 0.0
    dt = 0.02
    for _ in range(20000):
        qq = 0.5 * rho * v * v
        Tv = np.interp(v, Vg, Tgv)
        L = qq * S * CLg + Tv * math.sin(tl)
        Dd = qq * S * (CD0 + K * CLg * CLg)
        a = (Tv * math.cos(tl) - Dd - mu * max(mass * G0 - L, 0.0)) / mass
        if a <= 0:
            return float("inf")
        v += a * dt
        x += v * dt
        if v >= v_rot and 0.5 * rho * v * v * S * CLmax >= 1.21 * (mass * G0 - np.interp(v, Vg, Tgv) * math.sin(tl)):
            return x
    return float("inf")


def _python_mtow(perf_in, lo, hi, runway):
    if _python_run(perf_in, lo) > runway:
        return float("nan")
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if _python_run(perf_in, mid) <= runway:
            lo = mid
        else:
            hi = mid
    return lo


def _plane(tilt, runway):
    p = DesignProject()
    p.wing_draft.area, p.wing_draft.alpha_cruise = 1.0, 3.0
    p.requirements.V_stall_max = 13.0
    p.requirements.takeoff_run = runway
    p.power_draft.tilt = tilt
    w = p.keep_wing()
    p.tail_draft.wing = w.name
    p.power_draft.set = p.keep_set().name
    return p


def test_ground_run_in_core_matches_python_bit_for_bit():
    from aerosim.model.universal import build_model
    for tilt, runway in ((0.0, 50.0), (8.0, 50.0), (4.0, 6.0)):
        p = _plane(tilt, runway)
        ac, asm = pw.assemble(p.draft_aircraft(), p.requirements, p.rules, None, p.airfoil_map())
        pf = pw.performance(ac, asm, p.requirements)
        wr = asm["set"]["wing"]
        us = [u for u in ac.propulsion if u.enabled]
        tl = math.radians(sum(u.tilt for u in us) / len(us))
        S = build_model(ac).S
        CLg = wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"])
        Vg, Tgv = np.r_[0.0, pf["V"]], np.r_[pf["T0"], pf["T"]]
        rs = asm["trim"].get("rot_speed")
        args = (p.requirements.rho, S, CLg, pf["CD0"], pf["K"], wr["CLmax"], p.requirements.mu_roll, tl, Vg, Tgv, rs)
        assert pf["s_to"] == _python_run(args, asm["mass"])
        ref = [_python_run(args, m) for m in pf["masses"]]
        assert np.array_equal(pf["s_curve"], ref)
        ref_mtow = _python_mtow(args, max(asm["empty"], 0.1), max(4 * asm["mass"], 1.0), runway)
        assert (math.isnan(ref_mtow) and math.isnan(pf["mtow_runway"])) or pf["mtow_runway"] == ref_mtow
