"""Estado compartilhado da GUI: a aeronave em edição, o catálogo e o Simulation Manager.

As abas não se falam diretamente: mudam o estado e emitem `changed`.
"""
from __future__ import annotations

import copy
import os

from PyQt6 import QtCore

from aerosim.interfaces.project_store import IProjectStore
from aerosim.interfaces.simulation import ISimulationManager
from aerosim.model.aircraft import Aircraft
from aerosim.model.catalog import Catalog, builtin_catalog

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class AppState(QtCore.QObject):
    changed = QtCore.pyqtSignal(str)          # motivo: "geometry", "mass", "wind", "load", ...
    selected = QtCore.pyqtSignal(str)         # componente selecionado (chave da geometria)

    def __init__(self, manager: ISimulationManager, aircraft: Aircraft, catalog: Catalog | None = None,
                 projects: "IProjectStore | None" = None):
        super().__init__()
        self.manager = manager
        if projects is None:
            from aerosim.data.projects import JsonProjectStore
            projects = JsonProjectStore()
        self.projects = projects          # biblioteca "meus aviões" (só pela interface)
        self.aircraft = aircraft
        self.original = copy.deepcopy(aircraft)      # para o botão Restaurar
        self.catalog = catalog or builtin_catalog()
        self.path: str | None = None
        cat_file = os.path.join(ROOT, "data", "catalog", "catalog.cfg")
        if catalog is None and os.path.exists(cat_file):
            try:
                from aerosim.data import load_catalog
                self.catalog = builtin_catalog().merge(load_catalog(cat_file))
            except Exception:
                pass

    def set_aircraft(self, ac: Aircraft, path: str | None = None, keep_original: bool = False) -> None:
        self.aircraft = ac
        self.path = path
        if not keep_original:
            self.original = copy.deepcopy(ac)
        self.changed.emit("load")

    def notify(self, reason: str = "geometry") -> None:
        self.aircraft.apply_constraints()
        self.changed.emit(reason)
