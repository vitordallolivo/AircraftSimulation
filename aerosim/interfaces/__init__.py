"""Interfaces entre as camadas:  GUI -> Simulation Manager -> Sim  (+ Aircraft Data).

    IAircraftSource / ICatalogSource   dados da aeronave e do catálogo (aircraft_source.py)
    ISimBackend / ISimSession          núcleo numérico (backend.py)
    ISimulation / ISimulationManager   simulações e o orquestrador (simulation.py)
"""
from .aircraft_source import IAircraftSource, ICatalogSource
from .backend import ISimBackend, ISimSession, LogChunk, RunStatus, SimSpec, TrimKind
from .simulation import (CancelledError, ISimulation, ISimulationManager, ParamSpec, PlotSpec,
                         RunContext, SimResult)

__all__ = [
    "IAircraftSource", "ICatalogSource", "ISimBackend", "ISimSession", "LogChunk", "RunStatus",
    "SimSpec", "TrimKind", "CancelledError", "ISimulation", "ISimulationManager", "ParamSpec",
    "PlotSpec", "RunContext", "SimResult",
]
