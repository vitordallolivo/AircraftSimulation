"""Polar 2D dos perfis (camada abaixo dos métodos 3D): uma fonte por `ISectionPolar` e um cache só.

Fontes (`SOURCES`):
    "modelo"      a mesma hipótese do núcleo, em 2D — c_l = a0 (α − α_L0) até perto do estol, misturado com a
                  placa plana 2 sen²α cos α pela sigmoide de Beard e McLain (Small Unmanned Aircraft, 2012,
                  eq. 4.10), com o α de transição ajustado para o pico ser o c_l,max do perfil
    "neuralfoil"  c_l, c_d, c_m do contorno real pela rede do NeuralFoil (Sharpe, 2023), que vem com o AeroSandbox
    "arquivo"     a polar exportada pelo XFLR5/XFOIL (texto ou CSV)

Cache: a mesma pergunta (perfil, fonte, Re, α) não recalcula. Fica na memória e, para as fontes caras
(NeuralFoil), também em disco, em `cache_dir()` (variável AEROSIM_CACHE, senão ~/.cache/aerosim): o lltdrek
reescreve as polares a cada rodada e a etapa Asa refaz a cada mudança.

    p = section_polar(af, alphas, Re, "neuralfoil")      # {'alpha', 'cl', 'cd', 'cm'} (cópias)
    SOURCES["arquivo"].polar(af, alphas, Re, polar_file="s1223.txt")
"""
from __future__ import annotations

import hashlib
import math
import os
import re
from collections import OrderedDict
from functools import lru_cache

import numpy as np

from aerosim.interfaces.aero import ISectionPolar
from aerosim.model.airfoil import Airfoil

M_BLEND = 50.0


def _sigma(al, a0, M=M_BLEND):
    e1 = np.exp(np.clip(-M * (al - a0), -50, 50))
    e2 = np.exp(np.clip(M * (al + a0), -50, 50))
    return (1 + e1 + e2) / ((1 + e1) * (1 + e2))


def _cl_model(al, a_lin, cl0, a0):
    sg = _sigma(al, a0)
    return (1 - sg) * (cl0 + a_lin * al) + sg * 2 * np.sign(al) * np.sin(al) ** 2 * np.cos(al)


@lru_cache(maxsize=64)
def _stall_angle(a_lin: float, cl0: float, clmax: float) -> float:
    al = np.linspace(0, 0.9, 3000)
    lo, hi = 0.02, 0.8
    for _ in range(50):
        a0 = 0.5 * (lo + hi)
        if _cl_model(al, a_lin, cl0, a0).max() > clmax:
            hi = a0
        else:
            lo = a0
    return 0.5 * (lo + hi)


def model_polar(af: Airfoil, alphas_deg) -> dict[str, np.ndarray]:
    a_lin = af.cl_alpha
    cl0 = -a_lin * math.radians(af.zero_lift_angle())
    a0 = _stall_angle(round(a_lin, 6), round(cl0, 6), round(af.cl_max, 6))
    al = np.radians(np.asarray(alphas_deg, float))
    cl = _cl_model(al, a_lin, cl0, a0)
    sg = _sigma(al, a0)
    cd = af.cd0 + sg * 1.2 * np.sin(al) ** 2
    return dict(alpha=np.asarray(alphas_deg, float), cl=cl, cd=cd, cm=np.full_like(cl, af.moment_ac()))


def neuralfoil_polar(af: Airfoil, alphas_deg, Re: float) -> dict[str, np.ndarray]:
    import neuralfoil as nf
    a = np.asarray(alphas_deg, float)
    r = nf.get_aero_from_coordinates(coordinates=af.outline(), alpha=a, Re=Re, model_size="large")
    return dict(alpha=a, cl=np.asarray(r["CL"], float), cd=np.asarray(r["CD"], float),
                cm=np.asarray(r["CM"], float))


def read_polar_file(path: str) -> dict:
    """{'Re': Re, 'alpha', 'cl', 'cd', 'cm'} de uma polar exportada (texto do XFLR5/XFOIL ou CSV)"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    Re = float("nan")
    head = None
    rows = []
    for ln in lines:
        m = re.search(r"Re\s*=\s*([\d.]+)\s*e\s*([+-]?\d+)", ln)
        if m:
            Re = float(m.group(1)) * 10 ** int(m.group(2))
        else:
            m = re.search(r"Re\s*=\s*([\d.]+)(?!\s*e)", ln)
            if m and not math.isfinite(Re):
                Re = float(m.group(1))
        parts = [p for p in re.split(r"[,\s;]+", ln.strip()) if p]
        low = [p.lower() for p in parts]
        if head is None and "alpha" in low and "cl" in low:
            head = low
            continue
        if head is None:
            continue
        try:
            vals = [float(p) for p in parts]
        except ValueError:
            continue
        if len(vals) >= len(head) or len(vals) >= 3:
            rows.append(vals)
    if head is None or not rows:
        raise ValueError(f"não achei a tabela 'alpha CL CD ...' em {os.path.basename(path)}")
    a = np.array([r[:len(head)] + [np.nan] * (len(head) - len(r[:len(head)])) for r in rows], float)
    col = lambda k: a[:, head.index(k)] if k in head else np.full(len(a), np.nan)
    order = np.argsort(col("alpha"))
    return dict(Re=Re, alpha=col("alpha")[order], cl=col("cl")[order], cd=col("cd")[order],
                cm=np.nan_to_num(col("cm")[order]))


# ------------------------------------------------------------------ as fontes
class ModelSection(ISectionPolar):
    name, title, fidelity = "modelo", "modelo do simulador (linear + estol)", "modelo"

    def polar(self, af, alphas_deg, Re, polar_file=""):
        return model_polar(af, alphas_deg)


class NeuralFoilSection(ISectionPolar):
    name, title, fidelity, cost = "neuralfoil", "NeuralFoil (rede sobre o contorno)", "painel", "caro"

    def available(self, af, polar_file=""):
        try:
            import neuralfoil  # noqa: F401
        except ImportError:
            return "NeuralFoil não instalado (vem com o AeroSandbox)"
        if not (af.coords or (af.path and os.path.exists(af.path)) or _is_naca4(af.name)):
            return f"o perfil '{af.name}' não tem contorno (.dat ou NACA de 4 dígitos)"
        return None

    def polar(self, af, alphas_deg, Re, polar_file=""):
        return neuralfoil_polar(af, alphas_deg, Re)


class FileSection(ISectionPolar):
    name, title, fidelity = "arquivo", "polar exportada (XFLR5/XFOIL)", "painel"

    def available(self, af, polar_file=""):
        return None if polar_file and os.path.exists(polar_file) else "sem arquivo de polar"

    def polar(self, af, alphas_deg, Re, polar_file=""):
        p = read_polar_file(polar_file)
        a = np.asarray(alphas_deg, float)
        out = {k: np.interp(a, p["alpha"], p[k], left=np.nan, right=np.nan) for k in ("cl", "cd", "cm")}
        out.update(alpha=a, Re=p["Re"])
        return out


SOURCES: dict[str, ISectionPolar] = {s.name: s for s in (ModelSection(), NeuralFoilSection(), FileSection())}


def _is_naca4(name: str) -> bool:
    return "naca" in name.lower() and len("".join(ch for ch in name if ch.isdigit())) == 4


# ------------------------------------------------------------------ cache
MAX_MEMORY = 512
_MEM: OrderedDict = OrderedDict()
VERSION = 1                     # mude se uma fonte mudar o que calcula (invalida o disco)


def cache_dir() -> str:
    return os.environ.get("AEROSIM_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "aerosim")


def airfoil_key(af: Airfoil) -> str:
    """identifica o perfil pelo que muda a polar (nome, contorno, números e se está invertido)"""
    h = hashlib.sha1()
    mtime = os.path.getmtime(af.path) if af.path and os.path.exists(af.path) else 0
    if mtime:                       # o contorno é o do arquivo (a data dele já está na chave)
        coords = b""
    elif af.coords:
        coords = np.asarray(af.coords, float).round(6).tobytes()
    else:                           # NACA: o contorno que outline() vai gerar (ele preenche coords depois)
        coords = _naca_bytes(af.name) if _is_naca4(af.name) else b""
    h.update(repr((af.name, af.path, mtime, af.cl_alpha, af.alpha0, af.cl_max, af.cd0, af.cm_ac, af.inverted)).encode())
    h.update(coords)
    return h.hexdigest()


@lru_cache(maxsize=128)
def _naca_bytes(name: str) -> bytes:
    from aerosim.model.airfoil import naca4
    return np.asarray(naca4(name).tolist(), float).round(6).tobytes()


def _key(af, a: np.ndarray, Re: float, source: str, polar_file: str) -> str:
    h = hashlib.sha1()
    pf = (polar_file, os.path.getmtime(polar_file)) if polar_file and os.path.exists(polar_file) else ("", 0)
    h.update(repr((VERSION, airfoil_key(af), source, pf, round(float(Re), -3))).encode())
    h.update(np.asarray(a, float).round(6).tobytes())
    return h.hexdigest()


def _disk_path(key: str) -> str:
    return os.path.join(cache_dir(), "polar2d", key[:2], key + ".npz")


def _disk_read(key: str):
    try:
        with np.load(_disk_path(key)) as z:
            return {k: z[k] for k in z.files}
    except Exception:
        return None


def _disk_write(key: str, p: dict) -> None:
    path = _disk_path(key)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + f".{os.getpid()}.tmp.npz"
        np.savez(tmp, **{k: np.asarray(v, float) for k, v in p.items() if k in ("alpha", "cl", "cd", "cm", "Re")})
        os.replace(tmp, path)
    except OSError:                 # sem permissão/espaço: fica só na memória
        pass


def clear_cache(disk: bool = False) -> None:
    _MEM.clear()
    if disk:
        import shutil
        shutil.rmtree(os.path.join(cache_dir(), "polar2d"), ignore_errors=True)


def _copy(p: dict) -> dict:
    return {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in p.items()}


def section_polar(af: Airfoil, alphas_deg, Re: float, source: str = "modelo", polar_file: str = "") -> dict:
    """a polar 2D pela fonte pedida (guardada: memória; fontes caras também em disco). Se a fonte não serve
    para o perfil (sem contorno, sem arquivo), usa o modelo"""
    src = SOURCES.get(source, SOURCES["modelo"])
    if src.name != "modelo" and src.available(af, polar_file):
        src, source = SOURCES["modelo"], "modelo"
    a = np.asarray(alphas_deg, float)
    key = _key(af, a, Re, source, polar_file)
    p = _MEM.get(key)
    if p is None and src.cost == "caro":
        p = _disk_read(key)
    if p is None:
        p = src.polar(af, a, Re, polar_file)
        if src.cost == "caro":
            _disk_write(key, p)
    _MEM[key] = p
    _MEM.move_to_end(key)
    while len(_MEM) > MAX_MEMORY:
        _MEM.popitem(last=False)
    return _copy(p)


def write_lltdrek_polar(path: str, af: Airfoil, Res: list[float], source: str = "modelo",
                        polar_file: str = "") -> None:
    """arquivo de polar no formato do lltdrek: blocos  RE,<Re> / cm0,<cm0> / α,c_l ... / linha vazia"""
    al = np.arange(-20.0, 25.01, 0.5)
    with open(path, "w") as f:
        for Re in Res:
            p = section_polar(af, al, Re, source, polar_file)
            cm0 = float(np.interp(0.0, p["alpha"], p["cm"]))
            f.write(f"RE,{Re:.6g}\ncm0,{cm0:.6f}\n")
            for a, cl in zip(p["alpha"], p["cl"]):
                f.write(f"{a:.3f},{cl:.6f}\n")
            f.write("\n")
