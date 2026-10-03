"""Estado compartilhado da GUI: a aeronave em edição, o catálogo e o Simulation Manager.

As abas não se falam diretamente: mudam o estado e emitem `changed`.

Desfazer/refazer (Ctrl+Z / Ctrl+Y): cada mudança (`notify` ou `touch`) guarda o estado de antes —
a aeronave e os valores das abas registradas em `register` (formulários e tabelas das simulações).
Mudanças seguidas em menos de 0,6 s viram um passo só.
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
        self._undo: list = []
        self._redo: list = []
        self._views: dict = {}            # chave → (ler, escrever) valores de uma aba
        self._busy = False
        self._burst = QtCore.QTimer(self)
        self._burst.setSingleShot(True)
        self._burst.setInterval(600)
        self._burst.timeout.connect(self._settle)
        self._snap = self._capture()

    def set_aircraft(self, ac: Aircraft, path: str | None = None, keep_original: bool = False) -> None:
        self.aircraft = ac
        self.path = path
        if not keep_original:
            self.original = copy.deepcopy(ac)
        self.touch()
        self.changed.emit("load")

    def notify(self, reason: str = "geometry") -> None:
        self.aircraft.apply_constraints()
        self.touch()
        self.changed.emit(reason)

    # ------------------------------------------------------------------ desfazer / refazer
    def register(self, key: str, get, put) -> None:
        """uma aba entra no desfazer: `get()` lê os valores dela, `put(v)` os recoloca"""
        self._views[key] = (get, put)
        self._snap[1][key] = copy.deepcopy(get())

    def _capture(self):
        return copy.deepcopy(self.aircraft), {k: copy.deepcopy(g()) for k, (g, _) in self._views.items()}

    def _settle(self):
        self._snap = self._capture()

    def touch(self) -> None:
        """algo vai mudar/mudou: o estado de antes vira um passo de desfazer"""
        if self._busy:
            return
        if not self._burst.isActive():
            self._undo.append(self._snap)
            del self._undo[:-60]
            self._redo.clear()
        self._burst.start()

    def can_undo(self) -> bool:
        return bool(self._undo)

    def undo(self) -> bool:
        return self._step(self._undo, self._redo)

    def redo(self) -> bool:
        return self._step(self._redo, self._undo)

    def _step(self, src: list, dst: list) -> bool:
        if self._burst.isActive():
            self._burst.stop()
            self._settle()
        if not src:
            return False
        dst.append(self._capture())
        ac, views = src.pop()
        self._busy = True
        try:
            self.aircraft = copy.deepcopy(ac)
            self.changed.emit("load")
            for k, (_, put) in self._views.items():
                if k in views:
                    put(copy.deepcopy(views[k]))
        finally:
            self._busy = False
        self._settle()
        return True
