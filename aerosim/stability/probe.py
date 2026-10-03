"""Acesso ao núcleo para as análises de estabilidade: uma sessão configurada com a aeronave,
coeficientes com momentos em qualquer ponto, massa/CG/inércia e posições úteis (trem principal)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import ISimBackend
from aerosim.model.universal import AircraftModel, build_model

G0 = 9.80665
D = math.radians(0.5)


class Probe:
    def __init__(self, backend: ISimBackend, model, rho: float | None = None):
        """model: o modelo universal (uma configuração `Aircraft` é convertida aqui, uma vez)"""
        self.model = model if isinstance(model, AircraftModel) else build_model(model)
        self.ac = self.model.aircraft
        self.S, self.c, self.b = self.model.S, self.model.c, self.model.b
        self.rho = rho if rho is not None else self.ac.environment.rho
        self.translator = backend.translator
        self.s = backend.session_for(self.model, overrides={"env": {"rho": self.rho}})
        mp = self.s.mass_props()
        self.m, self.cg, self.I = mp["m"], np.array(mp["cg"]), mp["I"]
        self.W = self.m * G0

    def close(self):
        self.s.close()

    def __enter__(self):
        return self

    def __exit__(self, *e):
        self.close()

    # ------------------------------------------------------------------ coeficientes
    def C(self, V, alpha=0.0, beta=0.0, ref=None, p=0.0, q=0.0, r=0.0, de=0.0, da=0.0, dr=0.0):
        ref = list(self.cg) if ref is None else list(ref)
        raw = self.s.aero_coeffs_ex(V, alpha, beta, p, q, r, de, da, dr, ref=ref)
        return self.translator.from_native(raw, self.model)

    def deriv(self, V, alpha, key_in, outs, ref=None, step=D, **kw):
        """derivadas centrais de `outs` em relação a α, β, p, q, r ou a um comando (rad, rad/s)"""
        kp, km = dict(kw), dict(kw)
        if key_in == "alpha":
            kp["alpha"], km["alpha"] = alpha + step, alpha - step
        else:
            kp["alpha"] = km["alpha"] = alpha
            kp[key_in], km[key_in] = kw.get(key_in, 0.0) + step, kw.get(key_in, 0.0) - step
        cp, cm = self.C(V, ref=ref, **kp), self.C(V, ref=ref, **km)
        return {o: (cp[o] - cm[o]) / (2 * step) for o in outs}

    def neutral_point(self, V, alpha=math.radians(2.0)) -> float:
        """x_np (corpo) = x_ref + c C_mα / C_Lα  (manche fixo)"""
        d = self.deriv(V, alpha, "alpha", ("CL", "Cm"), ref=[0.0, 0.0, self.cg[2]])
        return self.c * d["Cm"] / d["CL"]

    def alpha_for_CL(self, V, CL, de=0.0, lo=-0.3, hi=0.6) -> float | None:
        """α com C_L pedido (bisseção no ramo linear, até o pico)"""
        al = np.radians(np.arange(-10, 30.01, 0.5))
        cl = np.array([self.C(V, a, de=de)["CL"] for a in al])
        i = int(np.argmax(cl))
        if CL > cl[i]:
            return None
        lo, hi = al[0], al[i]
        for _ in range(50):
            m = 0.5 * (lo + hi)
            if self.C(V, m, de=de)["CL"] < CL:
                lo = m
            else:
                hi = m
        return 0.5 * (lo + hi)

    def CLmax(self, V, de=0.0) -> float:
        al = np.radians(np.arange(-5, 30.01, 0.25))
        return float(max(self.C(V, a, de=de)["CL"] for a in al))

    def Vs(self, CLmax=None) -> float:
        CLm = CLmax if CLmax is not None else self.CLmax(15.0)
        return math.sqrt(2 * self.W / (self.rho * self.S * CLm))

    # ------------------------------------------------------------------ geometria
    def main_gear(self) -> np.ndarray:
        legs = [l for l in self.ac.gear.legs() if l.kind == "main"]
        if not legs:
            return np.array([self.cg[0] - 0.05, 0.0, self.cg[2] + 0.2])
        return np.array([np.mean([l.x for l in legs]), 0.0, np.mean([l.z for l in legs])])

    def thrust(self, V, thr=1.0) -> tuple[float, float, float]:
        """(T total, z da linha de tração média ponderada, Σ T·y) a V"""
        T = zT = Ty = 0.0
        units = [u for u in self.ac.propulsion if u.enabled]
        for i, u in enumerate(units):
            t = self.s.prop_point(i, V, thr)["T"]
            T += t
            zT += t * u.z
            Ty += t * u.y
        return T, (zT / T if T > 0 else 0.0), Ty

    def frac(self, x) -> float:
        return 100 * self.model.mac_frac(x)

    def x_of(self, pct) -> float:
        return self.model.x_at_mac(pct / 100)
