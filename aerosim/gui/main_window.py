"""Janela principal: uma aba por área (na ordem do projeto: dimensionamento, aerodinâmica, estabilidade,
propulsão, desempenho, missão) e, no fim, a Montagem (onde o avião se monta e se edita peça por peça).
Feita para caber em 1366 × 768.

As áreas que têm etapas da sprint (gui/design) viram subabas: primeiro as etapas que criam o avião do
zero (Perfil → Asa → Empenagem → Motores), por último "Avião montado" (a análise detalhada do avião
aberto). A etapa Motores manda o avião para a Montagem."""
from __future__ import annotations

import os

from PyQt6 import QtGui, QtWidgets

from aerosim.data import load_aircraft, load_catalog, save_aircraft
from aerosim.model.templates import TEMPLATES, empty

from .state import ROOT, AppState
from .tabs.config_tab import ConfigTab
from .tabs.simulation_tab import SimulationTab

FILTER = "Avião ou projeto (*.cfg *.json *.xlsx)"
TEMPLATE_NAMES = {"empty": "Vazio (montar do zero)", "conventional": "Convencional (original)", "flying_wing": "Asa voadora",
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
        from aerosim.interfaces.simulation import AREAS
        from .design import LAST_TAB, STAGES
        sims = sorted(state.manager.simulations(),
                      key=lambda s: AREAS.index(s.area) if s.area in AREAS else len(AREAS))
        self.area_tabs: dict = {}               # área → a aba dela (a primeira simulação da área)
        for sim in sims:
            stages = STAGES.get(sim.area)
            if not stages:
                tab = SimulationTab(state, sim)
                self.area_tabs.setdefault(sim.area, tab)
                self.tabs.addTab(tab, sim.title)
                continue
            sub = QtWidgets.QTabWidget()
            sub.setDocumentMode(True)
            for title, cls in stages:
                sub.addTab(cls(state), title)
            sub.addTab(SimulationTab(state, sim), LAST_TAB.get(sim.area, "Avião montado"))
            self.area_tabs.setdefault(sim.area, sub)
            self.tabs.addTab(sub, sim.title)
        self.config = ConfigTab(state)
        self.tabs.addTab(self.config, "Montagem")
        self._menus()
        self._design_label()
        self._toolbar()
        state.changed.connect(lambda r: self._title() if r == "load" else None)
        state.ui_get, state.ui_put = self.ui_state, self.set_ui_state
        self.setAcceptDrops(True)                    # soltar um .json de projeto ou de avião abre ele
        self._title()

    # ------------------------------------------------------------------ onde a interface está (vai no projeto)
    def ui_state(self) -> dict:
        sub = self.tabs.currentWidget()
        return dict(tab=self.tabs.tabText(self.tabs.currentIndex()),
                    sub=sub.currentIndex() if isinstance(sub, QtWidgets.QTabWidget) else 0)

    def set_ui_state(self, ui: dict) -> None:
        titles = [self.tabs.tabText(i) for i in range(self.tabs.count())]
        if ui.get("tab") in titles:
            self.tabs.setCurrentIndex(titles.index(ui["tab"]))
            sub = self.tabs.currentWidget()
            if isinstance(sub, QtWidgets.QTabWidget) and 0 <= int(ui.get("sub", 0)) < sub.count():
                sub.setCurrentIndex(int(ui.get("sub", 0)))

    def dragEnterEvent(self, ev):
        if ev.mimeData().hasUrls():
            ev.acceptProposedAction()

    def dropEvent(self, ev):
        for u in ev.mimeData().urls():
            if u.isLocalFile():
                self.open_path(u.toLocalFile())
                self._remember_design_dir()
                break

    def open_path(self, path: str, quiet: bool = False) -> None:
        """abre uma pasta de sprint, um projeto antigo (.json com etapas/estudos/Montagem) ou um arquivo de asa:
        volta de onde parou; um avião vai para a Montagem"""
        from aerosim.design import store
        try:
            if store.is_sprint_path(path):
                self.state.save_design()
                p, folder = store.open_path(path)
                data = os.path.join(ROOT, "data") + os.sep
                if os.path.abspath(folder).startswith(data):      # exemplo do repositório: grava fora de data/
                    root = getattr(self.state.projects, "root", None) or os.path.expanduser("~")
                    folder = os.path.join(root, "sprint", os.path.basename(folder.rstrip(os.sep)))
                self.state.open_design(p, folder)
                self._design_label()
                if not quiet:
                    self.show_design_summary()
            else:
                self.state.set_aircraft(load_aircraft(path), path)
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro", str(e))

    def show_design_summary(self) -> None:
        """o que está guardado no projeto aberto"""
        from html import escape
        rows = "".join(f"<tr><td><b>{escape(k)}</b></td><td>{escape(v)}</td></tr>"
                       for k, v in self.state.design.summary())
        QtWidgets.QMessageBox.information(
            self, "Projeto aberto", f"<p>{escape(self.state.design_dir)}</p><table cellspacing=6>{rows}</table>")

    def show_assembly(self):
        self.tabs.setCurrentWidget(self.config)

    def show_area(self, area: str):
        """vai para a análise do avião montado de uma área (a última subaba: "Avião montado")"""
        w = self.area_tabs.get(area)
        if w is None:
            return
        self.tabs.setCurrentWidget(w)
        if isinstance(w, QtWidgets.QTabWidget):
            w.setCurrentIndex(w.count() - 1)

    def _menus(self):
        m = self.menuBar().addMenu("&Arquivo")
        new = m.addMenu("Novo a partir de")
        new.addAction(TEMPLATE_NAMES["empty"]).triggered.connect(lambda: self.state.set_aircraft(empty()))
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
        pj = self.menuBar().addMenu("&Projeto da sprint")
        pj.addAction("Novo projeto (do zero) numa pasta…", self.design_new)
        pj.addAction("Abrir pasta da sprint…", self.design_open)
        pj.addAction("Abrir projeto antigo ou arquivo de asa (.json)…", self.design_open_file)
        pj.addAction("Gravar em outra pasta…", self.design_save_as)
        pj.addAction("Mostrar a pasta", self.design_show_dir)
        pj.addAction("O que está guardado…", self.show_design_summary)
        self._design_where = pj.addAction("")
        self._design_where.setEnabled(False)
        e = self.menuBar().addMenu("&Editar")
        self.undo_a = e.addAction("Desfazer", QtGui.QKeySequence.StandardKey.Undo, self.state.undo)
        self.redo_a = e.addAction("Refazer", self.state.redo)
        self.redo_a.setShortcuts([QtGui.QKeySequence("Ctrl+Y"), QtGui.QKeySequence("Ctrl+Shift+Z")])

    # ------------------------------------------------------------------ projeto da sprint
    def _design_label(self):
        self._design_where.setText(f"gravado sozinho em {self.state.design_dir} (um arquivo por asa)")

    def _remember_design_dir(self):
        """a próxima vez o programa abre nesta pasta"""
        from PyQt6 import QtCore
        QtCore.QSettings("aerosim", "aerosim").setValue("sprint_dir", self.state.design_dir)

    def _pick_dir(self, title: str) -> str:
        return QtWidgets.QFileDialog.getExistingDirectory(self, title, os.path.dirname(self.state.design_dir))

    def design_new(self):
        from aerosim.design import store
        from aerosim.design.project import DesignProject
        d = self._pick_dir("Pasta do projeto novo (cada asa vira um arquivo nela)")
        if not d:
            return
        self.state.save_design()
        if store.is_sprint_path(d):
            QtWidgets.QMessageBox.information(self, "Projeto da sprint", "Esta pasta já tem um projeto: abri ele.")
            self.open_path(d, quiet=True)
        else:
            self.state.open_design(DesignProject(), d)     # do zero: Montagem vazia também
            self.state.save_design()
        self._remember_design_dir()
        self._design_label()

    def design_open(self):
        d = self._pick_dir("Pasta da sprint")
        if d:
            self.open_path(d)
            self._remember_design_dir()
        self._design_label()

    def design_open_file(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Projeto da sprint", self.state.design_dir,
                                                        "Projeto ou asa (*.json)")
        if path:
            self.open_path(path)
            self._remember_design_dir()
        self._design_label()

    def design_save_as(self):
        d = self._pick_dir("Gravar o projeto da sprint nesta pasta")
        if d:
            self.state.design_dir = d
            self.state.save_design()
            self._remember_design_dir()
        self._design_label()

    def design_show_dir(self):
        from PyQt6 import QtCore, QtGui
        self.state.save_design()
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(self.state.design_dir))

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
        from .widgets import save_check
        st = self.state.projects
        if not save_check.confirm_save(self, self.state.aircraft, self.state.design):   # o que falta: salvar mesmo assim?
            return
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
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Abrir avião ou projeto", os.path.join(ROOT, "data"),
                                                        FILTER)
        if path:
            self.open_path(path)

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
