"""Simulation Manager: escolhe qual simulação roda, com que parâmetros, e entrega o
resultado. Guarda os checkpoints entre execuções (para retomar de A, B, C...).

A GUI só conhece a ISimulationManager; o núcleo só aparece como ISimBackend.
"""
from __future__ import annotations

import threading
from typing import Any, Callable

from aerosim.interfaces.backend import ISimBackend
from aerosim.interfaces.simulation import ISimulation, ISimulationManager, RunContext, SimResult
from aerosim.model.aircraft import Aircraft

from .checkpoints import CheckpointStore
from .simulations import BUILTIN


class SimulationManager(ISimulationManager):
    def __init__(self, backend: ISimBackend | None = None, simulations: list[ISimulation] | None = None,
                 checkpoint_dir: str | None = None):
        if backend is None:
            from aerosim.backend import default_backend
            backend = default_backend()
        self.backend = backend
        self.shared: dict = {}          # o que uma simulação deixa para outra (ex.: a polar da aba Aerodinâmica)
        self._sims: dict[str, ISimulation] = {}
        for s in simulations if simulations is not None else [cls() for cls in BUILTIN]:
            self.register(s)
        self.checkpoints = CheckpointStore(checkpoint_dir)

    def register(self, sim: ISimulation) -> None:
        if not sim.name:
            raise ValueError("simulação sem nome")
        self._sims[sim.name] = sim

    def simulations(self) -> list[ISimulation]:
        return list(self._sims.values())

    def get(self, name: str) -> ISimulation:
        return self._sims[name]

    def run(self, name: str, aircraft: Aircraft, params: dict[str, Any] | None = None,
            on_chunk: Callable | None = None, on_progress: Callable | None = None,
            cancel: threading.Event | None = None) -> SimResult:
        sim = self.get(name)
        p = sim.defaults(aircraft, params or {})
        p.update(params or {})
        ctx = RunContext(backend=self.backend, aircraft=aircraft, params=p, checkpoints=self.checkpoints,
                         shared=self.shared,
                         on_chunk=on_chunk or (lambda c: None), on_progress=on_progress or (lambda f, m: None),
                         cancel=cancel or threading.Event())
        return sim.run(ctx)
