"""Polar da aeronave para quem precisa dela, com cache (a mesma pergunta não roda de novo).

`solve(solver, model, case)` é por onde todo método 3D roda: a resposta fica guardada pela chave
(configuração inteira + método + versão dele + caso) na memória e, para os métodos caros (lltdrek,
AeroSandbox, AVL...), também em disco, em `<cache_dir()>/polar3d` (AEROSIM_CACHE, senão ~/.cache/aerosim).
Uma polar que veio do cache sai com `source = "cache"`.

`aircraft_polar` devolve a última polar que a aba Aerodinâmica calculou para ESTA configuração
(guardada em `shared["aero_polar"]` pelo manager) ou, se não houver, roda o método principal
(lltdrek; o modelo interno se o lltdrek não estiver instalado) sobre o modelo universal.
"""
from __future__ import annotations

import copy
import gzip
import hashlib
import json
import os
import pickle
from collections import OrderedDict

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, IAeroSolver

from .sections import cache_dir

KEY = "aero_polar"
VERSION = 1                     # mude se a chave ou o formato do disco mudar
MAX_MEMORY = 64
_MEM: OrderedDict = OrderedDict()


def signature(model) -> str:
    """identifica a configuração (para não reaproveitar a polar de outro avião)"""
    from aerosim.model.serialize import to_dict
    d = to_dict(model.aircraft)
    for s in d.get("surfaces", []):
        s.get("airfoil", {}).pop("coords", None)
    return hashlib.sha1(json.dumps(d, sort_keys=True, default=str).encode()).hexdigest()


def polar_key(solver: IAeroSolver, model, case: AeroCase) -> str:
    """configuração inteira (com os contornos dos perfis) + método + caso"""
    from aerosim.model.serialize import to_dict
    h = hashlib.sha1()
    h.update(json.dumps(to_dict(model.aircraft), sort_keys=True, default=str).encode())
    h.update(repr((VERSION, solver.name, getattr(solver, "version", 1), float(case.V), float(case.alpha_d),
                   tuple(round(float(x), 9) for x in case.ref), round(float(case.rho), 9), case.section,
                   int(case.n_span))).encode())
    h.update(np.asarray(case.alphas, float).round(9).tobytes())
    return h.hexdigest()


def _disk_path(key: str) -> str:
    return os.path.join(cache_dir(), "polar3d", key[:2], key + ".pkl.gz")


def _disk_read(key: str) -> AeroPolar | None:
    try:
        with gzip.open(_disk_path(key), "rb") as f:
            p = pickle.load(f)
        return p if isinstance(p, AeroPolar) else None
    except Exception:
        return None


def _disk_write(key: str, pol: AeroPolar) -> None:
    path = _disk_path(key)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with gzip.open(tmp, "wb") as f:
            pickle.dump(pol, f, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, path)
    except OSError:
        pass


def clear_cache(disk: bool = False) -> None:
    _MEM.clear()
    if disk:
        import shutil
        shutil.rmtree(os.path.join(cache_dir(), "polar3d"), ignore_errors=True)


def solve(solver: IAeroSolver, model, case: AeroCase, use_cache: bool = True) -> AeroPolar:
    """a polar pelo método, guardada (memória; disco para os caros). Devolve uma cópia"""
    fid = getattr(solver, "fidelity", "")
    if not use_cache:
        pol = solver.solve(model, case)
        pol.source, pol.fidelity = pol.source or "calculado", pol.fidelity or fid
        return pol
    key = polar_key(solver, model, case)
    pol, src = _MEM.get(key), "cache"
    if pol is None and getattr(solver, "cost", "barato") == "caro":
        pol = _disk_read(key)
    if pol is None:
        pol, src = solver.solve(model, case), "calculado"
        pol.fidelity = pol.fidelity or fid
        if getattr(solver, "cost", "barato") == "caro":
            _disk_write(key, pol)
    _MEM[key] = pol
    _MEM.move_to_end(key)
    while len(_MEM) > MAX_MEMORY:
        _MEM.popitem(last=False)
    out = copy.deepcopy(pol)
    out.source = src
    return out


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
    pol = solve(so, model, case)
    remember(shared, model, pol, so.title, V)
    return pol, f"módulo de aerodinâmica ({so.title})" + (" — guardada" if pol.source == "cache" else "")
