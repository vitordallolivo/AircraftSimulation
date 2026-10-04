"""Página do dimensionamento inicial (mini-MDO): o otimizador do núcleo em tempo real.

Esquerda: tipo de aeronave, objetivo, otimizador e população (`design.mdo.MdoParams`); variáveis e
restrições vêm de "Condições e restrições…". Direita, em cima: os indivíduos (clicáveis) e o histórico
das asas com um slider — a planta do melhor até a iteração escolhida sobre o enxame daquela iteração,
atualizado a cada iteração enquanto roda. Embaixo, do indivíduo clicado: envelope (tração × arrasto no
MTOW), grandezas e restrições, 3D. Botões: levar para as etapas e conferir no 6GDL.
"""
from __future__ import annotations

import copy
import math
import threading
import traceback

import numpy as np
import pyqtgraph as pg
from PyQt6 import QtCore, QtWidgets

from aerosim.design import mdo
from aerosim.design import registry as rg

from ..state import AppState
from ..widgets.param_slider import HELP_MARK, DataclassForm

OK_C, BAD_C, BEST_C = "#2ca02c", "#d62728", "#1f4e8c"


class _Worker(QtCore.QObject):
    progress = QtCore.pyqtSignal(int, object)     # iteração, indivíduos até agora
    done = QtCore.pyqtSignal(object)
    failed = QtCore.pyqtSignal(str)

    def __init__(self, project, catalog, backend, cancel, job="opt", row=None, manager=None):
        super().__init__()
        self.project, self.catalog, self.backend, self.cancel = project, catalog, backend, cancel
        self.job, self.row, self.manager = job, row, manager

    def run(self):
        try:
            if self.job == "6gdl":
                self.done.emit(mdo.check_6dof(self.project, self.row, self.catalog, self.manager, self.backend))
                return
            rows, best, names = mdo.run(self.project, self.catalog, self.backend,
                                        lambda it, r: self.progress.emit(it, r), self.cancel)
            self.done.emit((rows, best, names))
        except Exception:
            self.failed.emit(traceback.format_exc(limit=4))


class MdoPage(QtWidgets.QWidget):
    title = "Mini-MDO (otimizador)"

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        from .pages import ReqBar
        self.state = state
        self.rows: list[dict] = []
        self.hist: list[dict] = []
        self.names: dict = {}
        self._thread = None
        self._cancel = threading.Event()
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.setChildrenCollapsible(False)
        QtWidgets.QHBoxLayout(self).addWidget(split)
        # ---- esquerda
        left = QtWidgets.QWidget()
        lv = QtWidgets.QVBoxLayout(left)
        lv.addWidget(ReqBar(state))
        t = QtWidgets.QLabel(f"<b>{self.title}</b>" + HELP_MARK)
        t.setToolTip(mdo.__doc__)
        lv.addWidget(t)
        self.form_box = QtWidgets.QVBoxLayout()
        lv.addLayout(self.form_box)
        self.form = None
        from .pages import VariablesTable
        self.bounds_w = QtWidgets.QWidget()                # vai para a primeira aba de baixo (larga)
        bv = QtWidgets.QVBoxLayout(self.bounds_w)
        bv.setContentsMargins(2, 2, 2, 2)
        self.vtable = VariablesTable(state)
        bv.addWidget(self.vtable)
        self.bounds_b = QtWidgets.QPushButton("Limites a partir das restrições")
        self.bounds_b.setToolTip("as restrições ativas viram limites: envergadura ≤ → máx. da envergadura, área ≥/≤ → "
                                 "mín./máx. da área, nº de motores → motores mín./máx.")
        self.bounds_b.clicked.connect(self.bounds_from_constraints)
        bv.addWidget(self.bounds_b)
        self.vars_lbl = QtWidgets.QLabel()
        self.vars_lbl.setWordWrap(True)
        self.vars_lbl.setStyleSheet("color:#555")
        lv.addWidget(self.vars_lbl)
        g = QtWidgets.QGridLayout()
        self.run_b = QtWidgets.QPushButton("▶ Otimizar")
        self.stop_b = QtWidgets.QPushButton("■ Parar")
        self.stop_b.setEnabled(False)
        self.apply_b = QtWidgets.QPushButton("Levar para as etapas")
        self.apply_b.setToolTip("o indivíduo selecionado vira o rascunho da Asa e de Motores e montagem")
        self.six_b = QtWidgets.QPushButton("★ Conferir no 6GDL")
        self.six_b.setToolTip("leva para as etapas, guarda asa, conjunto e avião, fecha o ponto de projeto e mede o "
                              "MTOW no simulador (aba Missão, modo MTOW)")
        for b in (self.apply_b, self.six_b):
            b.setEnabled(False)
        for i, b in enumerate((self.run_b, self.stop_b, self.apply_b, self.six_b)):
            g.addWidget(b, i // 2, i % 2)
        lv.addLayout(g)
        self.run_b.clicked.connect(self.start)
        self.stop_b.clicked.connect(self._cancel.set)
        self.apply_b.clicked.connect(self.apply)
        self.six_b.clicked.connect(self.check6)
        self.bar = QtWidgets.QProgressBar()
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        lv.addWidget(self.bar)
        lv.addWidget(self.msg)
        lv.addStretch(1)
        ls = QtWidgets.QScrollArea()
        ls.setWidgetResizable(True)
        ls.setWidget(left)
        split.addWidget(ls)
        # ---- direita
        right = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)      # em cima a busca, embaixo o indivíduo
        right.setChildrenCollapsible(False)
        top_w = QtWidgets.QWidget()
        top = QtWidgets.QHBoxLayout(top_w)
        top.setContentsMargins(0, 0, 0, 0)
        self.scatter = pg.PlotWidget()
        self.scatter.setBackground("w")
        self.scatter.showGrid(x=True, y=True, alpha=0.3)
        self.scatter.setLabel("bottom", "iteração")
        self.scatter.setMinimumHeight(230)
        self.scatter.addLegend(offset=(-10, -10))      # embaixo à direita: os pontos sobem com a busca
        self.pts_ok = pg.ScatterPlotItem(size=7, brush=pg.mkBrush(OK_C), pen=pg.mkPen(None), name="viável")
        self.pts_bad = pg.ScatterPlotItem(size=7, brush=pg.mkBrush(None), pen=pg.mkPen(BAD_C), name="não cumpre")
        self.best_line = pg.PlotDataItem(pen=pg.mkPen(BEST_C, width=2), name="melhor até a iteração")
        self.sel = pg.ScatterPlotItem(size=16, brush=pg.mkBrush(None), pen=pg.mkPen("#000", width=2))
        for it in (self.pts_ok, self.pts_bad, self.best_line, self.sel):
            self.scatter.addItem(it)
        self.pts_ok.sigClicked.connect(self._clicked)
        self.pts_bad.sigClicked.connect(self._clicked)
        top.addWidget(self.scatter, 3)
        hist = QtWidgets.QVBoxLayout()
        self.plan = pg.PlotWidget()
        self.plan.setBackground("w")
        self.plan.setAspectLocked(True)
        self.plan.showGrid(x=True, y=True, alpha=0.3)
        self.plan.setLabel("bottom", "y (m)")
        self.plan.setLabel("left", "x (m)")
        self.plan.setMinimumHeight(200)
        hist.addWidget(self.plan, 1)
        hs = QtWidgets.QHBoxLayout()
        self.slider = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal)
        self.slider.setRange(0, 0)
        self.slider.valueChanged.connect(self._show_iter)
        self.follow = True                     # durante a corrida o slider acompanha a última iteração
        self.slider.sliderPressed.connect(lambda: setattr(self, "follow", False))
        self.iter_lbl = QtWidgets.QLabel("—")
        self.iter_lbl.setMinimumWidth(80)
        hs.addWidget(QtWidgets.QLabel("histórico"))
        hs.addWidget(self.slider, 1)
        hs.addWidget(self.iter_lbl)
        hist.addLayout(hs)
        self.plan_lbl = QtWidgets.QLabel()
        self.plan_lbl.setWordWrap(True)
        self.plan_lbl.setStyleSheet("color:#334; font-size:11px")
        hist.addWidget(self.plan_lbl)
        top.addLayout(hist, 2)
        right.addWidget(top_w)
        self.tabs = QtWidgets.QTabWidget()
        self.tabs.addTab(self.bounds_w, "Variáveis e limites")
        self.env = pg.PlotWidget()
        self.env.setBackground("w")
        self.env.showGrid(x=True, y=True, alpha=0.3)
        self.env.setLabel("bottom", "V (m/s)")
        self.env.setLabel("left", "N")
        self.env.addLegend(offset=(5, 5))
        self.tabs.addTab(self.env, "Envelope (tração × arrasto no MTOW)")
        self.table = QtWidgets.QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["grandeza", "valor", "restrição"])
        self.table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.tabs.addTab(self.table, "Grandezas e restrições")
        try:
            from ..widgets.view3d import AircraftView
            self.view = AircraftView()
            self.tabs.addTab(self.view, "3D")
        except Exception:
            self.view = None
        right.addWidget(self.tabs)
        right.setSizes([400, 260])
        split.addWidget(right)
        split.setSizes([360, 990])
        self.selected: dict | None = None
        state.designChanged.connect(self._design_changed)
        self.rebuild_form()
        self.show_saved()

    # ------------------------------------------------------------------ formulário
    def rebuild_form(self):
        if self.form is not None:
            self.form_box.removeWidget(self.form)
            self.form.hide()
            self.form.setParent(None)
            self.form.deleteLater()
        self.form = DataclassForm(self.state.design.mdo)
        self.form.changed.connect(lambda *_: (self.state.design_edited("mdo"), self._vars_text()))
        self.form_box.addWidget(self.form)
        self._vars_text()

    def _vars_text(self):
        d = self.state.design
        var = [v.input.label + (f" [{v.lo:g}, {v.hi:g}]" if v.input.unit != "lista" else f" {{{', '.join(v.options)}}}")
               for v in d.variables if v.mode == "variável"]
        on = [c.text() for c in d.requirements.constraints if c.active]
        self.vars_lbl.setText("<b>variáveis</b>: " + ("; ".join(var) if var else "nenhuma (todas fixas: marque em "
                              "Condições e restrições → Variáveis)") + "<br><b>restrições</b>: " +
                              ("; ".join(on) if on else "nenhuma"))

    def _design_changed(self, stage):
        if stage == "load":
            self.rebuild_form()
            self.vtable.fill()
            self.show_saved()
        elif stage in ("requisitos", "variaveis"):
            self._vars_text()

    def bounds_from_constraints(self):
        changed = rg.bounds_from_constraints(self.state.design)
        self.vtable.fill()
        self.rebuild_form()
        self.state.design_edited("variaveis")
        self.msg.setText("limites das restrições: " + ("; ".join(changed) if changed else "nenhuma restrição ativa "
                                                         "limita uma variável (envergadura, área, nº de motores)"))

    # ------------------------------------------------------------------ rodar
    def start(self):
        if self._thread is not None:
            return
        bad = rg.check_bounds(self.state.design)
        if bad:
            self.msg.setText("<b>limites inválidos</b> (grandeza física precisa de mín. e máx.):<br>" + "<br>".join(bad))
            return
        self._cancel.clear()
        self.rows, self.hist = [], []
        self.follow = True
        mp = self.state.design.mdo
        self.bar.setRange(0, max(mp.iterations, 1))
        self.bar.setValue(0)
        self.msg.setText(f"{mp.method}: {mp.particles} × {mp.iterations} avaliações no núcleo…")
        self._run(_Worker(copy.deepcopy(self.state.design), self.state.catalog, self.state.manager.backend,
                          self._cancel))

    def _run(self, w: _Worker):
        self.run_b.setEnabled(False)
        self.stop_b.setEnabled(w.job == "opt")
        self.six_b.setEnabled(False)
        th = QtCore.QThread(self)
        w.moveToThread(th)
        th.started.connect(w.run)
        w.progress.connect(self._progress)
        w.done.connect(self._done if w.job == "opt" else self._done6)
        w.failed.connect(self._failed)
        for sig in (w.done, w.failed):
            sig.connect(th.quit)
        th.finished.connect(self._finished)
        self._thread, self._worker = th, w
        th.start()

    def _finished(self):
        self._thread = None
        self.run_b.setEnabled(True)
        self.stop_b.setEnabled(False)
        self.six_b.setEnabled(bool(self.rows))

    def _progress(self, it, rows):
        self.rows = rows
        self.bar.setValue(it + 1)
        self.redraw()

    def _done(self, res):
        rows, best, names = res
        self.rows, self.names = rows, names
        d = self.state.design
        d.mdo_runs = (d.mdo_runs + [mdo.MdoRun(copy.deepcopy(d.mdo), names, rows)])[-3:]   # dados de simulação
        self.state.design_edited("mdo")
        self.redraw()
        b = self.hist[-1] if self.hist else None
        skipped = names.get("skipped") or []
        self.msg.setText((f"melhor: {'viável' if b and b['feasible'] else 'nenhum viável'} — MTOW "
                          f"{b['mtow']:.2f} kg, EE {b['ee']:.2f}" if b else "sem resultado") +
                         (f". Fora do dimensionamento inicial (as etapas conferem): {'; '.join(skipped)}" if skipped else ""))
        if b:
            self.select(b)
            self.tabs.setCurrentWidget(self.env)

    def _failed(self, txt):
        self.msg.setText("erro:\n" + txt)

    def show_saved(self):
        runs = self.state.design.mdo_runs
        if self._thread is not None or not runs:
            return
        r = runs[-1]
        self.rows, self.names = list(r.rows), dict(r.names)
        self.follow = True
        self.redraw()
        self.msg.setText(f"resultado guardado no projeto: {r.params.method}, {r.params.kind}, {len(self.rows)} avaliações")
        self.six_b.setEnabled(bool(self.rows))

    # ------------------------------------------------------------------ gráficos
    def redraw(self):
        rows = self.rows
        self.hist = mdo.history(rows)
        obj = self.state.design.mdo.objective
        self.scatter.setLabel("left", "MTOW (kg)" if obj == "MTOW" else "EE = CP/PV")
        key = "mtow" if obj == "MTOW" else "ee"
        jit = lambda r: r["iter"] + 0.35 * ((r["particle"] * 0.618) % 1.0 - 0.5)
        ok = [r for r in rows if r["feasible"]]
        bad = [r for r in rows if not r["feasible"]]
        self.pts_ok.setData([jit(r) for r in ok], [r[key] for r in ok], data=ok)
        self.pts_bad.setData([jit(r) for r in bad], [r[key] for r in bad], data=bad)
        self.best_line.setData([h["iter"] for h in self.hist], [h[key] for h in self.hist])
        n = len(self.hist)
        self.slider.blockSignals(True)
        self.slider.setRange(0, max(n - 1, 0))
        if self.follow:
            self.slider.setValue(max(n - 1, 0))
        self.slider.blockSignals(False)
        self._show_iter(self.slider.value())

    def _show_iter(self, k):
        self.plan.clear()
        if not self.hist:
            self.iter_lbl.setText("—")
            return
        k = min(max(k, 0), len(self.hist) - 1)
        h = self.hist[k]
        wings = 2 if self.state.design.mdo.kind == "biplano" else 1
        for r in (r for r in self.rows if r["iter"] == h["iter"]):      # o enxame da iteração, apagado
            p = mdo.planform(r, wings)
            self.plan.plot(p["x"], p["y"], pen=pg.mkPen(OK_C if r["feasible"] else BAD_C, width=1, style=QtCore.Qt.PenStyle.DotLine))
        p = mdo.planform(h, wings)
        self.plan.plot(p["x"], p["y"], pen=pg.mkPen(BEST_C, width=3))
        self.iter_lbl.setText(f"{h['iter'] + 1} / {len(self.hist)}")
        two = h["airfoil_tip"] != h["airfoil"] and self.state.design.mdo.tip_airfoil
        self.plan_lbl.setText(
            f"melhor até a iteração {h['iter'] + 1}: b = {h['span']:.2f} m, S = {h['area']:.3f} m², λ = {h['taper']:.2f}, "
            f"perfil {h['airfoil']}" + (f" → {h['airfoil_tip']} na ponta" if two else "") +
            f"; {h['motors']}× {h['motor']} + {h['propeller']}; MTOW {h['mtow']:.2f} kg, PV {h['pv']:.2f} kg, "
            f"EE {h['ee']:.2f}" + ("" if h["feasible"] else " — não cumpre as restrições"))

    def _clicked(self, item, points, *_):
        if points:
            self.follow = False
            self.select(points[0].data())

    # ------------------------------------------------------------------ indivíduo
    def select(self, r: dict):
        self.selected = r
        self.apply_b.setEnabled(True)
        self.six_b.setEnabled(self._thread is None)
        key = "mtow" if self.state.design.mdo.objective == "MTOW" else "ee"
        self.sel.setData([r["iter"] + 0.35 * ((r["particle"] * 0.618) % 1.0 - 0.5)], [r[key]])
        try:
            ev = mdo.evaluate(self.state.design, r, self.state.catalog, self.state.manager.backend)
        except Exception:
            self.msg.setText("erro ao refazer o indivíduo:\n" + traceback.format_exc(limit=3))
            return
        self.env.clear()
        self.env.plot(ev["V"], ev["T"], pen=pg.mkPen("#1f77b4", width=2.4), name="tração disponível")
        q = ev["q"]
        D = np.where(np.isfinite(ev["D"]), ev["D"], np.nan)                # só V = 0 (infinito) fica de fora
        self.env.plot(ev["V"], D, pen=pg.mkPen(BAD_C, width=2.4), name="arrasto = tração requerida (voo nivelado)",
                      connect="finite")
        Dmin = float(np.nanmin(D)) if np.isfinite(D).any() else 1.0
        self.env.setYRange(0, 3 * max(float(np.max(ev["T"])), Dmin), padding=0.02)   # enquadra; o zoom mostra o resto
        if math.isfinite(q.get("V_S", float("nan"))):
            self.env.addItem(pg.InfiniteLine(q["V_S"], angle=90, pen=pg.mkPen("#7f7f7f", style=QtCore.Qt.PenStyle.DashLine)))
        cons = self.state.design.requirements.constraints
        rows = []
        for k, v in q.items():
            qq = rg.QUANTITIES.get(k)
            label = qq.label if qq else {"V_LD": "V de (L/D) máx.", "LD": "(L/D) máx."}.get(k, k)
            unit = qq.unit if qq else ("m/s" if k == "V_LD" else "")
            c = next((c for c in cons if c.active and c.key == k), None)
            st = "" if c is None else (("✔ " if c.holds(v) else "✖ ") + f"{c.op} {rg.fmt(c.value)}")
            rows.append((f"{label} ({unit})" if unit else label, rg.fmt(v), st))
        self.table.setRowCount(len(rows))
        for i, row in enumerate(rows):
            for j, txt in enumerate(row):
                it = QtWidgets.QTableWidgetItem(txt)
                if txt.startswith("✖"):
                    it.setForeground(QtCore.Qt.GlobalColor.red)
                self.table.setItem(i, j, it)
        if self.view is not None:
            try:
                self.view.set_aircraft(mdo.sketch(self.state.design, r, self.state.catalog))
            except Exception:
                pass

    def apply(self):
        if self.selected is None:
            return
        mdo.apply(self.state.design, self.selected)
        self.state.design_edited("load")
        self.msg.setText("levado para os rascunhos de Asa e Motores e montagem (as etapas refazem as contas)")

    def check6(self):
        if self.selected is None or self._thread is not None:
            return
        from aerosim.manager import SimulationManager
        self.msg.setText("conferindo no 6GDL: asa, conjunto e avião guardados; ponto de projeto; MTOW no simulador…")
        self.bar.setRange(0, 0)
        self._six_project = self.state.design
        self._run(_Worker(self.state.design, self.state.catalog, self.state.manager.backend, self._cancel,
                          job="6gdl", row=self.selected, manager=SimulationManager(type(self.state.manager.backend)())))

    def _done6(self, out):
        self.bar.setRange(0, 1)
        self.bar.setValue(1)
        self.state.design_edited("load")
        self.msg.setText(f"'{out['aircraft']}': ponto de projeto {out['mtow_point']:.2f} kg; 6GDL {out['mtow6']:.2f} kg "
                         f"(dimensionamento inicial prometia {self.selected['mtow']:.2f} kg)")
