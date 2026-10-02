"""Aircraft (+ Mission) -> SimSpec (o dicionário que o núcleo entende, SI/radianos).

É a ponte entre o modelo de dados (independente do núcleo) e a interface ISimSession.
"""
from __future__ import annotations

import copy
import math
from dataclasses import asdict

from .aircraft import ANGLE_KEYS_AP, Aircraft
from .geometry import all_panels
from .catalog import POLY_VARS
from .massprops import dry_mass
from .mission import Mission

GEAR_KIND = {"steer": 0, "main": 1, "skid": 2}
D2R = math.pi / 180.0


def deep_update(base: dict, over: dict) -> dict:
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_update(base[k], v)
        else:
            base[k] = v
    return base


def compile_aircraft(ac: Aircraft, mission: Mission | None = None, overrides: dict | None = None) -> dict:
    ac = ac.copy()
    ac.apply_constraints()
    S, c, b = ac.references()
    dm = dry_mass(ac)
    I = dm["I"]
    f = ac.fuselage
    CDS = f.CDS if f.enabled else 0.0
    if ac.boom.enabled:
        CDS += 0.006 * math.pi * ac.boom.diameter * ac.boom.length    # atrito do tubo
    fus_r = f.aero_point if f.aero_point is not None else [f.x_nose - 0.4 * f.length, 0.0, f.z]
    units = [u for u in ac.propulsion if u.enabled]
    K = max(len(units), 1)
    props = []
    for u in units:
        pr, mo, ba = u.propeller, u.motor, u.battery
        n = min(len(pr.J), 64)
        tp = u.thrust_poly
        poly = dict(model=1 if u.thrust_model == "poly" else 0, poly=(list(tp.coefs) + [0.0] * 21)[:21],
                    poly_x=POLY_VARS.index(tp.x_var), poly_y=POLY_VARS.index(tp.y_var), poly_gain=tp.gain,
                    poly_rho_exp=tp.rho_exp, poly_rho0=tp.rho0, poly_xmax=tp.xmax, poly_ymax=tp.ymax)
        props.append(dict(**poly,
            r=[u.x, u.y, u.z], tilt=u.tilt * D2R, toe=u.toe * D2R, sense=float(u.sense), D=pr.D, Ip=pr.Ip,
            Jm=mo.Jm, Kv=mo.Kv, Rm=mo.Rm, B=mo.B, tauc=mo.tauc, Imax=mo.Imax, Voc=ba.Voc,
            Rint=ba.Rint * (K if ac.shared_battery else 1), yaw_mix=u.yaw_mix,
            J=pr.J[:n], CT=pr.CT[:n], CP=pr.CP[:n], n_pts=n))
    g = ac.gear
    e = ac.environment
    to = ac.takeoff
    ap = asdict(ac.autopilot)
    ap.pop("auto_calibrate")
    for k in ANGLE_KEYS_AP:
        ap[k] = ap[k] * D2R
    m = mission if mission is not None else ac.mission
    P = ac.payload
    spec = dict(
        m_dry=dm["m"], Ixx=I[0, 0], Iyy=I[1, 1], Izz=I[2, 2], Ixz=-I[0, 2], r_dry=list(dm["cg"]),
        Sref=S, cref=c, bref=b, Mst=ac.sim.Mst,
        fus_CDS=CDS, fus_Cma=f.Cma if f.enabled else 0.0, fus_Cnb=f.Cnb if f.enabled else 0.0,
        fus_CYb=f.CYb if f.enabled else 0.0, fus_r=list(fus_r),
        surf=all_panels(ac),
        prop=props,
        gear=[dict(r=[q.x, q.y, q.z], k=q.k, c=q.c, kind=GEAR_KIND[q.kind]) for q in g.legs()],
        tank=[dict(r=[t.x, t.y, t.z], side=t.side, fill=t.fill, rho=t.rho, zeta=t.zeta,
                   shape=0 if t.shape == "square" else 1) for t in ac.tanks],
        slosh_on=int(ac.sim.slosh),
        mu_roll=g.mu_roll, mu_lat=g.mu_lat, mu_brake=g.mu_brake, mu_skid=g.mu_skid, mu_landing=g.mu_landing,
        payload=dict(enabled=int(P.enabled), m=P.mass, r=[P.x, P.y, P.z], bay=P.bay, Fext_g=P.Fext_g,
                     mu_b=P.mu_b, CdS_chute=P.CdS_chute),
        env=dict(rho=e.rho, Vw10=e.wind_speed, wind_from=e.wind_from * D2R, wind_elev=e.wind_elev * D2R,
                 h_ref=e.h_ref, gust_T=e.gust_T, gust_U=list(e.gust_U), gust_on=int(e.gust)),
        takeoff=dict(VR=to.VR, sR=to.sR, de0=to.de0 * D2R, de1=to.de1 * D2R, rate_de=to.rate_de * D2R,
                     ht=to.ht, rate_thr=to.rate_thr, h_end=to.h_end),
        ap=ap,
        dt=ac.sim.dt, tmax=ac.sim.tmax, dtlog=ac.sim.dtlog,
        seg=m.segments(), event=m.core_events(),
    )
    if overrides:
        deep_update(spec, copy.deepcopy(overrides))
    return spec
