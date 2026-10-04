"""Etapa Perfil: a polar 2D de cada perfil candidato e os números que a asa vai usar.

O perfil pode vir de um .dat, de um código NACA de 4 dígitos, só de parâmetros (sem contorno: a1, α_L0,
c_l,max, c_d0, c_m) ou de uma polar já calculada (arquivo do XFLR5/XFOIL). A polar sai por uma de
três fontes, a que o perfil permitir:

    modelo      a mesma hipótese do simulador (rápido; c_d constante — não serve para comparar L/D)
    neuralfoil  rede neural sobre o contorno (precisa de contorno: .dat ou NACA)
    arquivo     a polar exportada pelo XFLR5/XFOIL (a do Re mais perto)

`fitted` devolve o perfil com a1, α_L0, c_l,max, c_d0 e c_m ajustados na polar escolhida: é ele que
segue para a asa, então a asa usa a fonte que você escolheu aqui.
"""
from __future__ import annotations

import copy
import math
import os
import re
from dataclasses import dataclass, field

import numpy as np

from aerosim.aero.sections import section_polar
from aerosim.model.airfoil import Airfoil, read_dat

from .fields import F

ALPHAS = np.arange(-8.0, 20.01, 0.5)
SOURCES = ("modelo", "neuralfoil", "arquivo")


@dataclass
class AirfoilEntry:
    airfoil: Airfoil = field(default_factory=Airfoil)
    source: str = F("modelo", "polar por", "", "modelo: rápido (c_d constante); neuralfoil: do contorno; "
                    "arquivo: polar do XFLR5/XFOIL", choices=SOURCES)
    polar_file: str = ""

    @property
    def name(self) -> str:
        return self.airfoil.name


def kind(af: Airfoil) -> str:
    """de onde vem o contorno: dat | naca | contorno | parâmetros (sem contorno)"""
    if af.path and os.path.exists(af.path):
        return "dat"
    if af.coords:
        return "contorno"
    digits = "".join(ch for ch in af.name if ch.isdigit())
    if "naca" in af.name.lower() and len(digits) == 4:
        return "naca"
    return "parâmetros"


def sources(entry: AirfoilEntry) -> list[str]:
    out = ["modelo"]
    if kind(entry.airfoil) != "parâmetros":
        try:
            import neuralfoil  # noqa: F401
            out.append("neuralfoil")
        except ImportError:
            pass
    if entry.polar_file and os.path.exists(entry.polar_file):
        out.append("arquivo")
    return out


def entry(af: Airfoil) -> AirfoilEntry:
    """candidato novo com a melhor fonte que ele permite (neuralfoil se tiver contorno e a rede instalada)"""
    e = AirfoilEntry(af)
    e.source = "neuralfoil" if "neuralfoil" in sources(e) else "modelo"
    return e


def from_dat(path: str) -> Airfoil:
    name, pts = read_dat(path)
    return Airfoil(name=name.strip() or os.path.splitext(os.path.basename(path))[0], path=path, coords=pts.tolist())


def from_naca(code: str) -> Airfoil:
    digits = "".join(ch for ch in code if ch.isdigit())
    return Airfoil(name=f"NACA {digits}")


# ------------------------------------------------------------------ polar de arquivo (XFLR5 / XFOIL)
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


# ------------------------------------------------------------------ polar e números
_CACHE: dict = {}


def polar(entry: AirfoilEntry, Re: float, alphas=ALPHAS, source: str | None = None) -> dict:
    """a polar no Re pedido (guardada: a mesma pergunta não recalcula — as etapas refazem a cada mudança)"""
    af = entry.airfoil
    a = np.asarray(alphas, float)
    key = (af.name, af.path, len(af.coords), af.cl_alpha, af.alpha0, af.cl_max, af.cd0, af.cm_ac, source or entry.source,
           entry.polar_file, os.path.getmtime(entry.polar_file) if entry.polar_file and os.path.exists(entry.polar_file)
           else 0, round(Re, -3), a.tobytes())
    if key not in _CACHE:
        if len(_CACHE) > 256:
            _CACHE.clear()
        _CACHE[key] = _polar(entry, Re, a, source)
    return {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in _CACHE[key].items()}


def _polar(entry: AirfoilEntry, Re: float, a: np.ndarray, source: str | None) -> dict:
    src = source or entry.source
    if src not in sources(entry):
        src = "modelo"
    if src == "arquivo":
        p = read_polar_file(entry.polar_file)
        out = {k: np.interp(a, p["alpha"], p[k], left=np.nan, right=np.nan) for k in ("cl", "cd", "cm")}
        out.update(alpha=a, source=src, Re=p["Re"])
        return out
    p = section_polar(entry.airfoil, a, Re, src)
    p.update(source=src, Re=Re)
    return p


def metrics(p: dict) -> dict:
    """c_l,max e α de estol, (c_l/c_d) máx. e onde, c_d mín., a1 e α_L0 (trecho linear), c_m"""
    a, cl, cd, cm = (np.asarray(p[k], float) for k in ("alpha", "cl", "cd", "cm"))
    ok = np.isfinite(cl) & np.isfinite(cd)
    a, cl, cd, cm = a[ok], cl[ok], cd[ok], cm[ok]
    if len(a) < 4:
        return {}
    i = int(np.argmax(cl))
    lin = (a >= -3) & (a <= 5) & (np.arange(len(a)) < i)
    if lin.sum() < 3:
        lin = np.arange(len(a)) <= max(i - 1, 2)
    k, b = np.polyfit(np.radians(a[lin]), cl[lin], 1)
    with np.errstate(divide="ignore", invalid="ignore"):
        ld = np.where(cd > 0, cl / cd, np.nan)
    j = int(np.nanargmax(ld))
    cd_const = float(np.ptp(cd[: i + 1])) < 1e-6
    return dict(cl_max=float(cl[i]), alpha_stall=float(a[i]), ld_max=float(ld[j]), cl_ld=float(cl[j]),
                alpha_ld=float(a[j]), cd_min=float(np.min(cd[: i + 1])), cl_alpha=float(k),
                alpha0=float(-math.degrees(b / k)) if k else 0.0, cm=float(np.mean(cm[lin])), cd_const=cd_const)


def fitted(af: Airfoil, p: dict) -> Airfoil:
    """o perfil com os números ajustados na polar (o que a asa usa)"""
    m = metrics(p)
    out = copy.deepcopy(af)
    if m:
        out.cl_alpha, out.alpha0, out.cl_max = m["cl_alpha"], m["alpha0"], m["cl_max"]
        out.cd0, out.cm_ac = m["cd_min"], m["cm"]
    return out


def drag_at(p: dict, cl) -> np.ndarray:
    """c_d da polar no c_l pedido (ramo antes do estol); acima do c_l,max: o c_d do estol"""
    a, c, d = (np.asarray(p[k], float) for k in ("alpha", "cl", "cd"))
    ok = np.isfinite(c) & np.isfinite(d)
    c, d = c[ok], d[ok]
    i = int(np.argmax(c))
    j0 = int(np.argmin(c[: i + 1])) if i > 0 else 0
    cc, dd = c[j0: i + 1], d[j0: i + 1]
    if len(cc) < 2:
        return np.full(np.shape(cl), float(np.nanmin(d)) if len(d) else 0.01)
    srt = np.argsort(cc)
    return np.interp(cl, cc[srt], dd[srt])
