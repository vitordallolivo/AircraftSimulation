"""Estado compartilhado da GUI: a aeronave em edição, o catálogo e o Simulation Manager.

Vários aviões podem ficar abertos ao mesmo tempo (as variantes da sprint): `fleet` guarda todos e
`aircraft` é o atual — toda aba roda e mostra o atual; trocar (`select`) emite "load".

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
        self.fleet: list[Aircraft] = [aircraft]       # aviões abertos (o atual é fleet[current])
        self.fleet_paths: list[str | None] = [None]
        self.current = 0
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
        self.fleet[self.current] = ac
        self.fleet_paths[self.current] = path
        if not keep_original:
            self.original = copy.deepcopy(ac)
        self.touch()
        self.changed.emit("load")

    # ------------------------------------------------------------------ vários aviões abertos
    def names(self) -> list[str]:
        return [a.name for a in self.fleet]

    def select(self, i: int) -> None:
        """troca o avião atual (todas as abas passam a mostrar e rodar este)"""
        if not 0 <= i < len(self.fleet) or i == self.current:
            return
        self.current = i
        self.aircraft = self.fleet[i]
        self.path = self.fleet_paths[i]
        self.original = copy.deepcopy(self.aircraft)
        self._undo.clear()
        self._redo.clear()
        self._settle()
        self.changed.emit("load")

    def add(self, ac: Aircraft | None = None, path: str | None = None) -> int:
        """abre mais um avião (sem `ac`: uma cópia do atual, para variar a partir dele) e passa para ele"""
        if ac is None:
            ac = copy.deepcopy(self.aircraft)
            ac.name = f"{ac.name} (variante {len(self.fleet) + 1})"
        self.fleet.append(ac)
        self.fleet_paths.append(path)
        self.select(len(self.fleet) - 1)
        return self.current

    def close(self, i: int | None = None) -> None:
        """fecha um avião (o último que sobra não fecha)"""
        i = self.current if i is None else i
        if len(self.fleet) <= 1 or not 0 <= i < len(self.fleet):
            return
        del self.fleet[i]
        del self.fleet_paths[i]
        if i < self.current or (i == self.current and i > 0):
            self.current -= 1
        self.current = min(self.current, len(self.fleet) - 1)
        self.aircraft = self.fleet[self.current]
        self.path = self.fleet_paths[self.current]
        self.original = copy.deepcopy(self.aircraft)
        self._undo.clear()
        self._redo.clear()
        self._settle()
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
            self.fleet[self.current] = self.aircraft
            self.changed.emit("load")
            for k, (_, put) in self._views.items():
                if k in views:
                    put(copy.deepcopy(views[k]))
        finally:
            self._busy = False
        self._settle()
        return True
