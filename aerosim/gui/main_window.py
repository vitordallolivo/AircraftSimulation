"""Janela principal: aba de configuração + uma aba por simulação do manager."""
from __future__ import annotations

import os

from PyQt6 import QtGui, QtWidgets

from aerosim.data import load_aircraft, load_catalog, save_aircraft
from aerosim.model.templates import TEMPLATES

from .state import ROOT, AppState
from .tabs.config_tab import ConfigTab
from .tabs.simulation_tab import SimulationTab

FILTER = "Aeronave (*.cfg *.json *.xlsx)"
TEMPLATE_NAMES = {"conventional": "Convencional (original)", "flying_wing": "Asa voadora",
                  "twin_boom": "Bimotor, convencional, tubo + cauda em V"}


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, state: AppState):
        super().__init__()
        self.state = state
        self.setWindowTitle("aerosim — simulador 6GDL")
        self.resize(1500, 920)
        self.tabs = QtWidgets.QTabWidget()
        self.setCentralWidget(self.tabs)
        self.config = ConfigTab(state)
        self.tabs.addTab(self.config, "Configuração")
        for sim in state.manager.simulations():
            self.tabs.addTab(SimulationTab(state, sim), sim.title)
        self._menus()
        state.changed.connect(lambda r: self._title() if r == "load" else None)
        self._title()

    def _menus(self):
        m = self.menuBar().addMenu("&Arquivo")
        new = m.addMenu("Novo a partir de")
        for k, f in TEMPLATES.items():
            a = new.addAction(TEMPLATE_NAMES.get(k, k))
            a.triggered.connect(lambda _=False, f=f: self.state.set_aircraft(f()))
        m.addAction("Abrir…", QtGui.QKeySequence.StandardKey.Open, self.open)
        m.addAction("Salvar", QtGui.QKeySequence.StandardKey.Save, self.save)
        m.addAction("Salvar como…", self.save_as)
        m.addSeparator()
        m.addAction("Importar catálogo (motores/hélices/baterias/conjuntos de tração)…", self.import_catalog)
        m.addAction("Importar planilha por mapa de células…", self.import_cellmap)
        m.addSeparator()
        m.addAction("Sair", self.close)

    def _title(self):
        p = self.state.path
        self.setWindowTitle(f"aerosim — {self.state.aircraft.name}" + (f"  [{os.path.basename(p)}]" if p else ""))

    def open(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Abrir aeronave", os.path.join(ROOT, "data", "aircraft"),
                                                        FILTER)
        if path:
            try:
                self.state.set_aircraft(load_aircraft(path), path)
            except Exception as e:
                QtWidgets.QMessageBox.critical(self, "Erro", str(e))

    def save(self):
        if not self.state.path:
            return self.save_as()
        save_aircraft(self.state.aircraft, self.state.path)

    def save_as(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Salvar aeronave", os.path.join(ROOT, "data", "aircraft"),
                                                        FILTER)
        if path:
            save_aircraft(self.state.aircraft, path)
            self.state.path = path
            self._title()

    def import_catalog(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Catálogo", os.path.join(ROOT, "data", "catalog"),
                                                        "Catálogo (*.cfg *.json *.xlsx)")
        if path:
            try:
                self.state.catalog = self.state.catalog.merge(load_catalog(path))
                self.state.changed.emit("catalog")
                QtWidgets.QMessageBox.information(self, "Catálogo",
                                                  f"{len(self.state.catalog.motors)} motores, "
                                                  f"{len(self.state.catalog.propellers)} hélices, "
                                                  f"{len(self.state.catalog.batteries)} baterias, "
                                                  f"{len(self.state.catalog.thrust_sets)} conjuntos de tração")
            except Exception as e:
                QtWidgets.QMessageBox.critical(self, "Erro", str(e))

    def import_cellmap(self):
        from aerosim.data.cellmap import CellMapAircraftSource
        xlsx, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Planilha", "", "Excel (*.xlsx)")
        if not xlsx:
            return
        mp, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Mapa de células", os.path.join(ROOT, "data", "mappings"),
                                                      "Mapa (*.json)")
        if not mp:
            return
        try:
            src = CellMapAircraftSource(mp, base=self.state.aircraft)
            ac = src.load(xlsx)
            self.state.catalog = self.state.catalog.merge(src.catalog)     # conjuntos de tração da planilha
            self.state.set_aircraft(ac, None)
            if src.warnings:
                QtWidgets.QMessageBox.warning(self, "Mapa de células", "\n".join(src.warnings[:30]))
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro", str(e))
