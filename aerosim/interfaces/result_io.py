"""SimResult ⇄ dicionário de JSON (para guardar no projeto o que já rodou e mostrar ao abrir sem rodar de novo).

numpy vira {"__nd__": lista, "dtype": ...} (texto e objeto viram lista simples); Check vira dicionário. O
registro no tempo (log) longo é reamostrado para `max_rows` linhas (os gráficos continuam iguais à vista; o
original pode ter dezenas de milhares de linhas).

    d = result_to_dict(res)           # json.dumps(d) funciona
    res = result_from_dict(d)
"""
from __future__ import annotations

import dataclasses
import math

import numpy as np

from .backend import LogChunk
from .simulation import Check, SimResult

MAX_ROWS = 2000          # o bastante para os gráficos (mais pontos que pixels)
SIG = 6                  # algarismos guardados, em relação ao maior valor de cada coluna (perto de zero: absoluto)


def _round(a: np.ndarray) -> np.ndarray:
    m = np.nanmax(np.abs(a)) if a.size and np.isfinite(a).any() else 0.0
    if not np.isfinite(m) or m == 0:
        return a
    return np.round(a, max(SIG - 1 - int(math.floor(math.log10(m))), 0))


def _enc(v):
    if isinstance(v, np.ndarray):
        if v.dtype.kind in "fiub":
            a = _round(v.astype(float)) if v.dtype.kind == "f" else v
            flat = [None if (isinstance(x, float) and not math.isfinite(x)) else x for x in a.ravel().tolist()]
            return {"__nd__": flat, "dtype": str(v.dtype), "shape": list(v.shape)}
        return {"__nd__": [_enc(x) for x in v.ravel().tolist()], "dtype": "object", "shape": list(v.shape)}
    if isinstance(v, np.generic):
        return _enc(v.item())
    if isinstance(v, float):
        return v if math.isfinite(v) else {"__float__": repr(v)}
    if isinstance(v, dict):
        return {str(k): _enc(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_enc(x) for x in v]
    if dataclasses.is_dataclass(v):
        return {k: _enc(x) for k, x in dataclasses.asdict(v).items()}
    return v


def _dec(v):
    if isinstance(v, dict):
        if "__nd__" in v:
            dt = v.get("dtype", "float64")
            shape = v.get("shape") or [len(v["__nd__"])]
            if dt == "object":
                a = np.empty(len(v["__nd__"]), dtype=object)
                a[:] = [_dec(x) for x in v["__nd__"]]
                return a.reshape(shape)
            data = [np.nan if x is None else x for x in v["__nd__"]]
            return np.array(data, dtype=dt).reshape(shape)
        if "__float__" in v:
            return float(v["__float__"])
        return {k: _dec(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_dec(x) for x in v]
    return v


def _thin(cols: dict, max_rows: int) -> dict:
    n = len(cols.get("t", ())) if cols else 0
    if n <= max_rows:
        return cols
    idx = np.unique(np.r_[np.linspace(0, n - 1, max_rows).round().astype(int), n - 1])
    return {k: (np.asarray(v)[idx] if np.ndim(v) and len(v) == n else v) for k, v in cols.items()}


def _thin_series(series: dict, max_rows: int) -> dict:
    """cada série (colunas do mesmo tamanho) com até `max_rows` pontos, as colunas com os mesmos índices"""
    out = {}
    for k, v in series.items():
        if isinstance(v, dict):
            ns = {len(x) for x in v.values() if isinstance(x, np.ndarray) and x.ndim == 1}
            if len(ns) == 1 and (n := ns.pop()) > max_rows:
                idx = np.unique(np.r_[np.linspace(0, n - 1, max_rows).round().astype(int), n - 1])
                v = {kk: (x[idx] if isinstance(x, np.ndarray) and x.ndim == 1 and len(x) == n else x)
                     for kk, x in v.items()}
        out[k] = v
    return out


def result_to_dict(res: SimResult, max_rows: int = MAX_ROWS) -> dict:
    log = None
    if res.log is not None and len(res.log):
        log = _enc(_thin(dict(res.log.columns), max_rows))
    series = {k: v for k, v in res.series.items() if not (isinstance(v, dict) and "_result" in v)}  # vista 3D: objetos
    return dict(log=log, series=_enc(_thin_series(series, max_rows)), summary=_enc(res.summary),
                events=_enc(res.events),
                status=res.status, checks=[_enc(c) for c in res.checks])


def result_from_dict(d: dict) -> SimResult:
    log = LogChunk(columns=_dec(d["log"])) if d.get("log") else None
    checks = [Check(**{k: c.get(k, "") for k in ("status", "item", "value", "criterion", "why", "fix", "group",
                                                   "source")}) for c in d.get("checks", [])]
    return SimResult(log=log, series=_dec(d.get("series") or {}), summary=_dec(d.get("summary") or {}),
                     events=_dec(d.get("events") or {}), status=d.get("status", "ok"), checks=checks)
