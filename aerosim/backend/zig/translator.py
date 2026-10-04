"""Tradutor modelo universal -> núcleo Zig (SimSpec: dicionário com os campos das structs extern).

Superfícies viram painéis (uma faixa entre estações consecutivas, de cada lado), com o centro
aerodinâmico a 25 % da corda média da faixa; o resto da configuração vira os campos do núcleo
(SI/radianos). O núcleo já devolve coeficientes nos eixos e nas adimensionalizações universais,
então `from_native` só filtra as chaves.
"""
from __future__ import annotations

import copy
import math
from dataclasses import asdict

import numpy as np

from aerosim.interfaces.translator import COEFFS, IModelTranslator
from aerosim.model.aircraft import ANGLE_KEYS_AP, panel_mix
from aerosim.model.catalog import POLY_VARS
from aerosim.model.universal import GROUP, AircraftModel, SurfaceModel, build_model

GEAR_KIND = {"steer": 0, "main": 1, "skid": 2}
D2R = math.pi / 180.0


def prop_native(u, rint_factor: float = 1.0) -> dict:
    """uma unidade propulsora (motor + hélice + bateria, ou polinômio de tração) como `PropUnit` do núcleo;
    usada pela simulação e pelo dimensionamento inicial"""
    pr, mo, ba = u.propeller, u.motor, u.battery
    n = min(len(pr.J), 64)
    tp = u.thrust_poly
    return dict(
        model=1 if u.thrust_model == "poly" else 0, poly=(list(tp.coefs) + [0.0] * 21)[:21],
        poly_x=POLY_VARS.index(tp.x_var), poly_y=POLY_VARS.index(tp.y_var), poly_gain=tp.gain,
        poly_rho_exp=tp.rho_exp, poly_rho0=tp.rho0, poly_xmax=tp.xmax, poly_ymax=tp.ymax,
        poly_xc=tp.x_const, poly_yc=tp.y_const,
        r=[u.x, u.y, u.z], tilt=u.tilt * D2R, toe=u.toe * D2R, tilt_range=u.tilt_range * D2R, sense=float(u.sense),
        D=pr.D, Ip=pr.Ip, Jm=mo.Jm, Kv=mo.Kv, Rm=mo.Rm, B=mo.B, tauc=mo.tauc, Imax=mo.Imax, Voc=ba.Voc,
        Rint=ba.Rint * rint_factor, yaw_mix=u.yaw_mix, J=pr.J[:n], CT=pr.CT[:n], CP=pr.CP[:n], n_pts=n)


def surface_panels(s: SurfaceModel) -> list[dict]:
    out = []
    sides = (1, -1) if s.mirror else (s.side if s.role == "device" else 0,)
    for k, (a, b, ctl) in enumerate(s.strips()):
        co = s.strip_coeffs[k] if s.strip_coeffs else dict(CLa=s.CLa, CL0=s.CL0, CLmax=s.CLmax, CD0=s.CD0, Cmac=s.Cmac)
        ds = b.s - a.s
        if ds < 1e-6:
            continue
        S = 0.5 * (a.chord + b.chord) * ds
        cm = S / ds
        mid = 0.5 * (a.le + b.le)
        inc = 0.5 * (a.twist + b.twist)
        tau = 0.0
        if ctl is not None:
            tau = ctl.tau
            inc += tau * ctl.deflection             # deflexão fixa (flape, flaperon baixado)
            if ctl.kind == "flap":
                tau = 0.0
        for side in sides:
            r = [float(mid[0] - 0.25 * cm), float(mid[1] * (1 if side >= 0 else -1)), float(mid[2])]
            out.append(dict(
                r=r, S=S, c=cm, AR=s.AR, e=s.oswald, dihedral=math.radians(s.dihedral), incidence=math.radians(inc),
                CLa=co["CLa"], CL0=co["CL0"], CLmax=co["CLmax"], CD0=co["CD0"], Cmac=co["Cmac"], tau=tau,
                mix=panel_mix(ctl.gains, side) if ctl is not None else [0.0, 0.0, 0.0], eta=s.eta,
                eps0=s.eps0, depsda=s.depsda, group=GROUP.get(s.role, 0), vertical=int(s.vertical), side=side,
                downwash=int(s.downwash)))
    return out


class ZigTranslator(IModelTranslator):
    name = "zig"

    def to_native(self, model: AircraftModel, mission=None, overrides: dict | None = None, **_) -> dict:
        ac = model.aircraft
        I = model.mass["I"]
        f = ac.fuselage
        CDS = f.CDS if f.enabled else 0.0
        CDS += sum(0.006 * math.pi * b.diameter * b.length for b in ac.booms if b.enabled)   # atrito dos tubos
        fus_r = f.aero_point if f.aero_point is not None else [f.x_nose - 0.4 * f.length, 0.0, f.z]
        units = [u for u in ac.propulsion if u.enabled]
        K = max(len(units), 1)
        props = [prop_native(u, K if ac.shared_battery else 1) for u in units]
        g = ac.gear
        e = ac.environment
        to = ac.takeoff
        ap = asdict(ac.autopilot)
        ap.pop("auto_calibrate")
        for k in ANGLE_KEYS_AP:
            ap[k] = ap[k] * D2R
        m = mission if mission is not None else model.mission
        P = ac.payload
        surf = []
        for s in model.surfaces:
            surf += surface_panels(s)
        spec = dict(
            m_dry=model.mass["m"], Ixx=I[0, 0], Iyy=I[1, 1], Izz=I[2, 2], Ixz=-I[0, 2], r_dry=list(model.mass["cg"]),
            Sref=model.S, cref=model.c, bref=model.b, Mst=ac.sim.Mst,
            fus_CDS=CDS, fus_Cma=f.Cma if f.enabled else 0.0, fus_Cnb=f.Cnb if f.enabled else 0.0,
            fus_CYb=f.CYb if f.enabled else 0.0, fus_r=list(fus_r),
            surf=surf, prop=props,
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
        pads = ac.airfield.pads(m)
        spec.update(pads=pads, n_pad=len(pads))
        if overrides:
            _deep_update(spec, copy.deepcopy(overrides))
        return spec

    def from_native(self, raw, model=None, **_) -> dict[str, float]:
        return {k: float(raw[k]) for k in raw if k in COEFFS or k in ("CL_wing", "CL_ht", "ratioCL")}


def _deep_update(base: dict, over: dict) -> dict:
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_update(base[k], v)
        else:
            base[k] = v
    return base


def native_spec(ac_or_model, mission=None, overrides: dict | None = None) -> dict:
    """atalho: configuração ou modelo -> SimSpec do núcleo"""
    model = ac_or_model if isinstance(ac_or_model, AircraftModel) else build_model(ac_or_model, mission)
    return ZigTranslator().to_native(model, mission=mission, overrides=overrides)
