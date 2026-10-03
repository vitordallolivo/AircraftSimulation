"""Polar da aeronave para quem precisa dela fora da aba Aerodinâmica (dimensionamento inicial,
envelope...). A polar é responsabilidade do módulo de aerodinâmica: aqui só se pede.

`aircraft_polar` devolve a última polar que a aba Aerodinâmica calculou para ESTA configuração
(guardada em `shared["aero_polar"]` pelo manager) ou, se não houver, roda o método principal
(lltdrek; núcleo Zig se o lltdrek não estiver instalado) sobre o modelo universal.
"""
from __future__ import annotations

import hashlib
import json

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar

KEY = "aero_polar"


def signature(model) -> str:
    """identifica a configuração (para não reaproveitar a polar de outro avião)"""
    from aerosim.model.serialize import to_dict
    d = to_dict(model.aircraft)
    for s in d.get("surfaces", []):
        s.get("airfoil", {}).pop("coords", None)
    return hashlib.sha1(json.dumps(d, sort_keys=True, default=str).encode()).hexdigest()


def remember(shared: dict | None, model, polar: AeroPolar, method: str, V: float) -> None:
    if shared is not None:
        shared[KEY] = dict(sig=signature(model), polar=polar, method=method, V=V)


def aircraft_polar(backend, model, V: float, shared: dict | None = None,
                   alphas=np.arange(-4.0, 20.01, 1.0)) -> tuple[AeroPolar, str]:
    """(polar universal, de onde veio)"""
    from . import all_solvers
    if shared and KEY in shared and shared[KEY]["sig"] == signature(model):
        e = shared[KEY]
        return e["polar"], f"aba Aerodinâmica ({e['method']}, V = {e['V']:g} m/s)"
    sols = {s.name: s for s in all_solvers(backend)}
    so = sols["lltdrek"] if sols["lltdrek"].available() is None else sols["zig"]
    case = AeroCase(V=V, alphas=np.asarray(alphas, float), ref=tuple(model.mass["cg"]),
                    rho=model.aircraft.environment.rho)
    pol = so.solve(model, case)
    remember(shared, model, pol, so.title, V)
    return pol, f"módulo de aerodinâmica ({so.title})"
