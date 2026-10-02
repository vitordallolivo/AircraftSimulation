"""Estado compartilhado da GUI: a aeronave em edição, o catálogo e o Simulation Manager.

As abas não se falam diretamente: mudam o estado e emitem `changed`.
"""
from __future__ import annotations

import os

from PyQt6 import QtCore

from aerosim.interfaces.simulation import ISimulationManager
from aerosim.model.aircraft import Aircraft
from aerosim.model.catalog import Catalog, builtin_catalog

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class AppState(QtCore.QObject):
    changed = QtCore.pyqtSignal(str)          # motivo: "geometry", "mass", "wind", "load", ...
    selected = QtCore.pyqtSignal(str)         # componente selecionado (chave da geometria)

    def __init__(self, manager: ISimulationManager, aircraft: Aircraft, catalog: Catalog | None = None):
        super().__init__()
        self.manager = manager
        self.aircraft = aircraft
        self.catalog = catalog or builtin_catalog()
        self.path: str | None = None
        cat_file = os.path.join(ROOT, "data", "catalog", "catalog.cfg")
        if catalog is None and os.path.exists(cat_file):
            try:
                from aerosim.data import load_catalog
                self.catalog = builtin_catalog().merge(load_catalog(cat_file))
            except Exception:
                pass

    def set_aircraft(self, ac: Aircraft, path: str | None = None) -> None:
        self.aircraft = ac
        self.path = path
        self.changed.emit("load")

    def notify(self, reason: str = "geometry") -> None:
        self.aircraft.apply_constraints()
        self.changed.emit(reason)
