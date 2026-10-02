"""Base comum das simulações: prepara a aeronave (calibração) e roda casos em paralelo."""
from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable

from aerosim.interfaces.simulation import ISimulation, RunContext
from aerosim.model.aircraft import Aircraft

from ..calibration import calibrate

WORKERS = max(1, min((os.cpu_count() or 2), 8))


def floats(v) -> list[float]:
    """'10, 12.5, 15' ou lista -> lista de floats"""
    if isinstance(v, str):
        return [float(x) for x in v.replace(";", ",").split(",") if x.strip()]
    if isinstance(v, (int, float)):
        return [float(v)]
    return [float(x) for x in v]


class SimulationBase(ISimulation):
    def prepare(self, ctx: RunContext) -> tuple[Aircraft, dict]:
        """cópia calibrada da aeronave + características estáticas"""
        ac = ctx.aircraft.copy()
        ctx.on_progress(0.0, "calibrando o piloto pela polar")
        info = calibrate(ctx.backend, ac)
        return ac, info

    def param(self, ctx: RunContext, key: str) -> Any:
        if key in ctx.params:
            return ctx.params[key]
        return self.defaults()[key]

    def parallel(self, ctx: RunContext, fn: Callable, items: list, label: str = "") -> list:
        """roda fn(item) em threads (cada uma com sua sessão no núcleo)"""
        out = [None] * len(items)
        done = 0

        def wrap(i_item):
            i, item = i_item
            ctx.check()
            return i, fn(item)
        with ThreadPoolExecutor(max_workers=WORKERS) as ex:
            for i, r in ex.map(wrap, list(enumerate(items))):
                out[i] = r
                done += 1
                ctx.on_progress(done / max(len(items), 1), f"{label} {done}/{len(items)}")
        return out
