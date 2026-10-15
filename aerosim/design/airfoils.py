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
from dataclasses import dataclass, field

import numpy as np

from aerosim.aero.sections import read_polar_file, section_polar  # noqa: F401 (read_polar_file: quem importa daqui)
from aerosim.model.airfoil import Airfoil, read_dat

from .fields import F

ALPHAS = np.arange(-16.0, 20.01, 0.5)
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


# ------------------------------------------------------------------ polar e números
def polar(entry: AirfoilEntry, Re: float, alphas=ALPHAS, source: str | None = None) -> dict:
    """a polar no Re pedido, pela fonte do candidato (ou a pedida); quem guarda é aerosim.aero.sections"""
    src = source or entry.source
    if src not in sources(entry):
        src = "modelo"
    p = section_polar(entry.airfoil, np.asarray(alphas, float), Re, src, entry.polar_file if src == "arquivo" else "")
    p["source"] = src
    p.setdefault("Re", Re)
    return p


def metrics(p: dict) -> dict:
    """c_l,max e α de estol, (c_l/c_d) máx. e onde, c_d mín., a1 e α_L0 (trecho linear), c_m.
    Perfil invertido (arqueado para baixo, como na EH): o lado útil é o do c_l negativo — c_l,max é o maior
    |c_l| e `inverted` fica True"""
    a, cl, cd, cm = (np.asarray(p[k], float) for k in ("alpha", "cl", "cd", "cm"))
    ok = np.isfinite(cl) & np.isfinite(cd)
    a, cl, cd, cm = a[ok], cl[ok], cd[ok], cm[ok]
    if len(a) < 4:
        return {}
    i = int(np.argmax(cl))
    j0 = int(np.argmin(cl[: i + 1])) if i > 0 else 0
    lo, hi = cl[j0], cl[i]
    mid = (np.arange(len(a)) >= j0) & (np.arange(len(a)) <= i)
    inverted = -lo > hi
    # trecho colado: c_l entre 15 % e 70 % do máximo do lado útil; a1 e α_L0 pela inclinação de Theil-Sen e
    # intercepto mediano (robusta a saltos de bolha/descolamento, como o do S1223 em Re baixo)
    lin = mid & ((cl <= 0.15 * lo) & (cl >= 0.7 * lo) if inverted else (cl >= 0.15 * hi) & (cl <= 0.7 * hi))
    if lin.sum() < 3:
        lin = mid if mid.sum() >= 3 else np.ones(len(a), bool)
    ar, cr = np.radians(a[lin]), cl[lin]
    ii, jj = np.triu_indices(len(ar), 1)              # Theil-Sen: mediana das inclinações de todos os pares
    k = float(np.median((cr[jj] - cr[ii]) / (ar[jj] - ar[ii])))
    b = float(np.median(cr - k * ar))
    with np.errstate(divide="ignore", invalid="ignore"):
        ld = np.where(cd > 0, (-cl if inverted else cl) / cd, np.nan)
    jl = int(np.nanargmax(ld))
    cd_const = float(np.ptp(cd[j0: i + 1])) < 1e-6
    ist = j0 if inverted else i
    return dict(cl_max=float(-lo if inverted else hi), alpha_stall=float(a[ist]), ld_max=float(ld[jl]),
                cl_ld=float(cl[jl]), alpha_ld=float(a[jl]), cd_min=float(np.min(cd[j0: i + 1])), cl_alpha=float(k),
                alpha0=float(-math.degrees(b / k)) if k else 0.0, cm=float(np.mean(cm[lin])), cd_const=cd_const,
                inverted=bool(inverted))


def fitted(af: Airfoil, p: dict) -> Airfoil:
    """o perfil com os números ajustados na polar (o que a asa usa)"""
    m = metrics(p)
    out = copy.deepcopy(af)
    if m:
        out.cl_alpha, out.alpha0, out.cl_max = m["cl_alpha"], m["alpha0"], m["cl_max"]
        out.cd0, out.cm_ac = m["cd_min"], m["cm"]
        if symmetric(af):           # em Re baixo a bolha desloca o ajuste; perfil simétrico tem α_L0 = c_m = 0
            out.alpha0, out.cm_ac = 0.0, 0.0
    return out


def symmetric(af: Airfoil) -> bool:
    if kind(af) == "parâmetros":
        return False
    from aerosim.model.airfoil import camber_line
    try:
        return float(np.max(np.abs(camber_line(af.outline())[1]))) < 0.003
    except Exception:
        return False


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
