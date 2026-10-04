"""Janela principal: uma aba por simulação do manager e, no fim, a Montagem (onde o avião se monta e
se edita peça por peça). Feita para caber em 1366 × 768.

A Montagem fica por último: as áreas trabalham nas abas de análise e a montagem junta as escolhas
num avião (o mesmo arquivo de sempre — o AeroDrive e o núcleo leem igual)."""
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
        scr = QtGui.QGuiApplication.primaryScreen()
        avail = scr.availableGeometry() if scr is not None else None
        w, h = (1366, 768) if avail is None else (min(1366, avail.width()), min(768, avail.height()))
        self.resize(w, h)
        self.tabs = QtWidgets.QTabWidget()
        self.setCentralWidget(self.tabs)
        for sim in state.manager.simulations():
            self.tabs.addTab(SimulationTab(state, sim), sim.title)
        self.config = ConfigTab(state)
        self.tabs.addTab(self.config, "Montagem")
        self._menus()
        self._toolbar()
        state.changed.connect(lambda r: self._title() if r == "load" else None)
        self._title()

    def _menus(self):
        m = self.menuBar().addMenu("&Arquivo")
        new = m.addMenu("Novo a partir de")
        for k, f in TEMPLATES.items():
            a = new.addAction(TEMPLATE_NAMES.get(k, k))
            a.triggered.connect(lambda _=False, f=f: self.state.set_aircraft(f()))
        m.addAction("Salvar avião (meus aviões)…", self.save_project)
        m.addAction("Meus aviões…", self.open_project)
        m.addSeparator()
        m.addAction("Abrir arquivo…", QtGui.QKeySequence.StandardKey.Open, self.open)
        m.addAction("Abrir ao lado (mais um avião aberto)…", self.open_beside)
        m.addAction("Nova variante do avião atual", lambda: self.state.add())
        m.addAction("Salvar", QtGui.QKeySequence.StandardKey.Save, self.save)
        m.addAction("Salvar como…", self.save_as)
        m.addSeparator()
        m.addAction("Importar catálogo (motores/hélices/baterias/conjuntos de tração)…", self.import_catalog)
        m.addAction("Importar planilha por mapa de células…", self.import_cellmap)
        m.addSeparator()
        m.addAction("Sair", self.close)
        e = self.menuBar().addMenu("&Editar")
        self.undo_a = e.addAction("Desfazer", QtGui.QKeySequence.StandardKey.Undo, self.state.undo)
        self.redo_a = e.addAction("Refazer", self.state.redo)
        self.redo_a.setShortcuts([QtGui.QKeySequence("Ctrl+Y"), QtGui.QKeySequence("Ctrl+Shift+Z")])

    # ------------------------------------------------------------------ meus aviões
    def _toolbar(self):
        tb = self.addToolBar("Aeronaves")
        tb.setMovable(False)
        tb.addAction("💾 Salvar avião…", self.save_project).setToolTip(
            "grava a configuração na pasta 'meus aviões' com o nome que você der (mesmo nome: atualiza)")
        tb.addAction("📂 Meus aviões…", self.open_project)
        self._root_label = QtWidgets.QLabel()
        tb.addWidget(self._root_label)
        self._root_label.setText(f"  pasta: {self.state.projects.root}")

    def save_project(self):
        st = self.state.projects
        name, ok = QtWidgets.QInputDialog.getText(self, "Salvar avião", "Nome do avião:",
                                                  text=self.state.aircraft.name)
        name = name.strip()
        if not ok or not name:
            return
        if st.exists(name) and QtWidgets.QMessageBox.question(
                self, "Salvar avião", f"Já existe '{name}'. Substituir?") != QtWidgets.QMessageBox.StandardButton.Yes:
            return
        try:
            info = st.save(self.state.aircraft, name)
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro", str(e))
            return
        self.state.path = info.path
        self.state.changed.emit("name")
        self._title()
        self.statusBar().showMessage(f"salvo em {info.path}", 6000)

    def open_project(self):
        dlg = ProjectsDialog(self.state, self)
        if dlg.exec() and dlg.chosen:
            try:
                self.state.set_aircraft(self.state.projects.load(dlg.chosen.path), dlg.chosen.path)
            except Exception as e:
                QtWidgets.QMessageBox.critical(self, "Erro", str(e))
        self._root_label.setText(f"  pasta: {self.state.projects.root}")

    def _title(self):
        p, st = self.state.path, self.state
        n = len(st.fleet)
        self.setWindowTitle(f"aerosim — {st.aircraft.name}" + (f"  ({st.current + 1}/{n} aviões abertos)" if n > 1 else "")
                            + (f"  [{os.path.basename(p)}]" if p else ""))

    def open(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Abrir aeronave", os.path.join(ROOT, "data", "aircraft"),
                                                        FILTER)
        if path:
            try:
                self.state.set_aircraft(load_aircraft(path), path)
            except Exception as e:
                QtWidgets.QMessageBox.critical(self, "Erro", str(e))

    def open_beside(self):
        """abre outro arquivo sem fechar o atual: os dois ficam na troca de aviões (◀ ▶) de todas as abas"""
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Abrir ao lado", os.path.join(ROOT, "data", "aircraft"),
                                                        FILTER)
        if path:
            try:
                self.state.add(load_aircraft(path), path)
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


class ProjectsDialog(QtWidgets.QDialog):
    """lista os aviões salvos (via IProjectStore): abrir, apagar, trocar a pasta"""

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state, self.chosen = state, None
        self.setWindowTitle("Meus aviões")
        self.resize(900, 480)
        v = QtWidgets.QVBoxLayout(self)
        src = QtWidgets.QHBoxLayout()
        self.which = QtWidgets.QComboBox()
        self.which.addItems(["meus aviões", "exemplos do programa (data/aircraft)"])
        self.which.currentIndexChanged.connect(lambda *_: self._fill())
        src.addWidget(QtWidgets.QLabel("Mostrar:"))
        src.addWidget(self.which, 1)
        v.addLayout(src)
        self.where = QtWidgets.QLabel()
        v.addWidget(self.where)
        self.table = QtWidgets.QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["nome", "salvo em", "resumo"])
        h = self.table.horizontalHeader()
        h.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        h.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        h.setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setWordWrap(True)
        self.table.doubleClicked.connect(self._open)
        v.addWidget(self.table)
        hb = QtWidgets.QHBoxLayout()
        for txt, fn in (("Abrir", self._open), ("Apagar", self._delete), ("Trocar pasta…", self._folder),
                        ("Fechar", self.reject)):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            hb.addWidget(b)
        v.addLayout(hb)
        self._fill()

    def _folder_now(self) -> str:
        return self.state.projects.root if self.which.currentIndex() == 0 else os.path.join(ROOT, "data", "aircraft")

    def _fill(self):
        from aerosim.data.projects import list_folder
        folder = self._folder_now()
        self.items = list_folder(folder)
        self.where.setText(f"pasta: {folder}  —  {len(self.items)} avião(ões)"
                           + ("" if self.items or self.which.currentIndex() else
                              "  (vazia: veja os exemplos do programa no seletor acima)"))
        self.table.setRowCount(len(self.items))
        for r, it in enumerate(self.items):
            for c, txt in enumerate((it.name, it.saved.replace("T", " "), it.summary)):
                self.table.setItem(r, c, QtWidgets.QTableWidgetItem(txt))
        self.table.resizeRowsToContents()

    def _row(self):
        r = self.table.currentRow()
        return self.items[r] if 0 <= r < len(self.items) else None

    def _open(self, *_):
        self.chosen = self._row()
        if self.chosen:
            self.accept()

    def _delete(self):
        it = self._row()
        if self.which.currentIndex() != 0:
            QtWidgets.QMessageBox.information(self, "Apagar", "Os exemplos do programa não são apagados daqui.")
            return
        if it and QtWidgets.QMessageBox.question(self, "Apagar", f"Apagar '{it.name}'?") == \
                QtWidgets.QMessageBox.StandardButton.Yes:
            os.remove(it.path)
            self._fill()

    def _folder(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(self, "Pasta dos aviões", self.state.projects.root)
        if d:
            from PyQt6 import QtCore
            self.state.projects.root = d
            QtCore.QSettings("aerosim", "aerosim").setValue("projects_root", d)
            self.which.setCurrentIndex(0)
            self._fill()
