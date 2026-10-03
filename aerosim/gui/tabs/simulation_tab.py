"""Aba genérica de uma simulação: formulário gerado pelos ParamSpec, botões rodar/parar,
progresso, resumo e gráficos em tempo real. Roda numa QThread; o núcleo devolve fatias
do registro que viram sinais Qt (thread-safe) e são desenhadas a ~15 Hz.
"""
from __future__ import annotations

import csv
import threading

import numpy as np
from PyQt6 import QtCore, QtGui, QtWidgets

from aerosim.interfaces.simulation import CancelledError, ISimulation, SimResult

from ..state import AppState
from ..widgets.plots import LivePlots, format_value


class _Worker(QtCore.QObject):
    chunk = QtCore.pyqtSignal(object)
    progress = QtCore.pyqtSignal(float, str)
    done = QtCore.pyqtSignal(object)
    failed = QtCore.pyqtSignal(str)

    def __init__(self, state: AppState, sim: ISimulation, params: dict, cancel: threading.Event):
        super().__init__()
        self.state, self.sim, self.params, self.cancel = state, sim, params, cancel

    def run(self):
        try:
            ac = self.state.aircraft.copy()
            res = self.state.manager.run(self.sim.name, ac, self.params, on_chunk=self.chunk.emit,
                                         on_progress=self.progress.emit, cancel=self.cancel)
            self.done.emit(res)
        except CancelledError:
            self.failed.emit("cancelado")
        except Exception as e:             # mostra o erro na aba em vez de derrubar a GUI
            import traceback
            self.failed.emit(f"{e}\n{traceback.format_exc(limit=4)}")


STATUS = {"ok": ("✔ OK", "#d9f2e6"), "atencao": ("⚠ ATENÇÃO", "#fff1cc"), "falha": ("✖ FALHA", "#fbdada"),
          "info": ("ℹ INFO", "#e8eef8")}


class SimulationTab(QtWidgets.QWidget):
    """formulário e gráficos vêm de `sim.parameters_for(aeronave)` e `sim.plots_for(aeronave)`
    e são refeitos quando a configuração muda (ex.: tirar a EH tira o dimensionamento da EH)"""

    def __init__(self, state: AppState, sim: ISimulation, parent=None):
        super().__init__(parent)
        self.state, self.sim = state, sim
        self.inputs: dict[str, QtWidgets.QWidget] = {}
        self.result: SimResult | None = None
        self._thread: QtCore.QThread | None = None
        self._cancel = threading.Event()
        self._specs_sig = None
        self._plots_sig = None
        self.split = split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        QtWidgets.QHBoxLayout(self).addWidget(split)

        side = QtWidgets.QWidget()
        sv = QtWidgets.QVBoxLayout(side)
        d = QtWidgets.QLabel(f"<b>{sim.title}</b><br>{sim.description}")
        d.setWordWrap(True)
        sv.addWidget(d)
        self.form_box = QtWidgets.QWidget()
        self.form = QtWidgets.QFormLayout(self.form_box)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self.form_box)
        sv.addWidget(scroll, 3)
        h = QtWidgets.QHBoxLayout()
        self.run_b = QtWidgets.QPushButton("▶ Rodar")
        self.stop_b = QtWidgets.QPushButton("■ Parar")
        self.save_b = QtWidgets.QPushButton("Exportar (xlsx/csv)…")
        self.stop_b.setEnabled(False)
        self.save_b.setEnabled(False)
        for b in (self.run_b, self.stop_b, self.save_b):
            h.addWidget(b)
        sv.addLayout(h)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 1000)
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        sv.addWidget(self.bar)
        sv.addWidget(self.msg)
        self.table = QtWidgets.QTableWidget(0, 2)
        self.table.setHorizontalHeaderLabels(["grandeza", "valor"])
        self.table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.table.verticalHeader().setVisible(False)
        sv.addWidget(self.table, 4)
        split.addWidget(side)

        # direita: uma rolagem só — gráficos grandes (legenda embaixo de cada um) e, no fim, o diagnóstico
        self.right_scroll = QtWidgets.QScrollArea()
        self.right_scroll.setWidgetResizable(True)
        self.right_scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        inner = QtWidgets.QWidget()
        self.right = QtWidgets.QVBoxLayout(inner)
        self.plots = LivePlots([])
        self.right.addWidget(self.plots)
        self.diag_title = QtWidgets.QLabel("<b>Diagnóstico</b> — passe o mouse ou clique numa linha para ver o "
                                           "porquê e o que mudar")
        self.diag = QtWidgets.QTableWidget(0, 4)
        self.diag.setHorizontalHeaderLabels(["estado", "verificação", "valor", "limite"])
        hh = self.diag.horizontalHeader()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        for i in range(1, 4):
            hh.setSectionResizeMode(i, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.diag.verticalHeader().setVisible(False)
        self.diag.setWordWrap(True)
        self.diag.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.diag.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.diag.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.diag_detail = QtWidgets.QLabel()
        self.diag_detail.setWordWrap(True)
        self.diag_detail.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.diag.currentCellChanged.connect(lambda r, *_: self._detail(r))
        for w in (self.diag_title, self.diag, self.diag_detail):
            w.hide()
            self.right.addWidget(w)
        self.right.addStretch(1)
        self.right_scroll.setWidget(inner)
        split.addWidget(self.right_scroll)
        split.setStretchFactor(0, 2)
        split.setStretchFactor(1, 8)
        split.setSizes([400, 1100])
        self._checks = []

        self.run_b.clicked.connect(self.start)
        self.stop_b.clicked.connect(self._cancel.set)
        self.save_b.clicked.connect(self.export)
        self._timer = QtCore.QTimer(self)
        self._timer.setInterval(66)
        self._timer.timeout.connect(lambda: self.plots.redraw())
        self._debounce = QtCore.QTimer(self)
        self._debounce.setSingleShot(True)
        self._debounce.setInterval(300)
        self._debounce.timeout.connect(self.reconfigure)
        state.changed.connect(lambda r: self._debounce.start() if r != "catalog" else None)
        self.reconfigure()

    # ------------------------------------------------------------------ montagem pela aeronave
    def reconfigure(self) -> None:
        """refaz o formulário e os gráficos se a aeronave (ou uma escolha como a norma) pede outros,
        mantendo os valores digitados"""
        if self._thread is not None:
            return
        ac = self.state.aircraft
        old = self.params() if self.inputs else {}
        specs = self.sim.parameters_for(ac, old)
        sig = tuple((p.key, p.label, p.kind, tuple(p.choices), p.group) for p in specs)
        if sig != self._specs_sig:
            while self.form.rowCount():
                self.form.removeRow(0)
            self.inputs = {}
            group = None
            for p in specs:
                if p.group and p.group != group:
                    h = QtWidgets.QLabel(f"<b>{p.group}</b>")
                    h.setStyleSheet("margin-top: 8px; color: #1f4e8c")
                    self.form.addRow(h)
                    group = p.group
                w = self._input(p)
                if p.key in old:
                    self._set(w, old[p.key])
                self.inputs[p.key] = w
                w.setToolTip(p.help or p.key)
                if isinstance(w, QtWidgets.QCheckBox):        # o texto vai na própria caixa: linha inteira
                    w.setText(p.label)
                    self.form.addRow(w)
                else:
                    lab = QtWidgets.QLabel(p.label + (f" ({p.unit})" if p.unit else ""))
                    lab.setWordWrap(True)
                    lab.setToolTip(p.help or p.key)
                    self.form.addRow(lab, w)
                if p.rebuild:
                    sig_ = w.currentTextChanged if isinstance(w, QtWidgets.QComboBox) else (
                        w.toggled if isinstance(w, QtWidgets.QCheckBox) else None)
                    if sig_ is not None:
                        sig_.connect(lambda *_: QtCore.QTimer.singleShot(0, self.reconfigure))
            self._specs_sig = sig
        self._set_plots(self.sim.plots_for(ac, self.params()))

    def _set_plots(self, specs) -> None:
        sig = tuple((s.key, s.title, s.ys, s.source, s.kind, s.live_ys) for s in specs)
        if sig == self._plots_sig:
            return
        new = LivePlots(specs, columns=1, row_height=560)
        self.right.replaceWidget(self.plots, new)
        self.plots.deleteLater()
        self.plots = new
        self._plots_sig = sig

    @staticmethod
    def _set(w, v):
        try:
            if isinstance(w, QtWidgets.QCheckBox):
                w.setChecked(bool(v))
            elif isinstance(w, QtWidgets.QComboBox):
                if w.findText(str(v)) >= 0:
                    w.setCurrentText(str(v))
            elif isinstance(w, QtWidgets.QSpinBox):
                w.setValue(int(v))
            elif isinstance(w, QtWidgets.QLineEdit):
                w.setText(str(v))
            else:
                w.setValue(float(v))
        except (TypeError, ValueError):
            pass

    def _input(self, p):
        if p.kind == "bool":
            w = QtWidgets.QCheckBox()
            w.setChecked(bool(p.default))
        elif p.kind == "choice":
            w = QtWidgets.QComboBox()
            w.addItems([str(c) for c in p.choices])
            w.setCurrentText(str(p.default))
        elif p.kind == "int":
            w = QtWidgets.QSpinBox()
            w.setRange(int(p.minimum if p.minimum is not None else -10**6), int(p.maximum if p.maximum is not None else 10**6))
            w.setValue(int(p.default))
        elif p.kind == "floats":
            w = QtWidgets.QLineEdit(str(p.default))
        else:
            w = QtWidgets.QDoubleSpinBox()
            # casas suficientes para o padrão e o mínimo (ex.: tolerância 1e-5)
            small = [abs(v) for v in (p.default, p.minimum, p.step) if isinstance(v, (int, float)) and v]
            w.setDecimals(max(4, min(10, max((-int(np.floor(np.log10(v))) + 2 for v in small), default=4))))
            w.setRange(p.minimum if p.minimum is not None else -1e9, p.maximum if p.maximum is not None else 1e9)
            w.setSingleStep(p.step or 0.1)
            w.setValue(float(p.default))
        return w

    def params(self) -> dict:
        out = {}
        for k, w in self.inputs.items():
            if isinstance(w, QtWidgets.QCheckBox):
                out[k] = w.isChecked()
            elif isinstance(w, QtWidgets.QComboBox):
                out[k] = w.currentText()
            elif isinstance(w, QtWidgets.QSpinBox):
                out[k] = w.value()
            elif isinstance(w, QtWidgets.QLineEdit):
                out[k] = w.text()
            else:
                out[k] = w.value()
        return out

    # ------------------------------------------------------------------ execução
    def start(self):
        if self._thread is not None:
            return
        self._cancel = threading.Event()
        self.stop_b.clicked.disconnect()
        self.stop_b.clicked.connect(self._cancel.set)
        self._set_plots(self.sim.plots_for(self.state.aircraft, self.params()))
        self.plots.clear()
        for w in (self.diag_title, self.diag, self.diag_detail):
            w.hide()
        self.table.setRowCount(0)
        self.msg.setText("rodando…")
        self.run_b.setEnabled(False)
        self.stop_b.setEnabled(True)
        self._thread = QtCore.QThread(self)
        self._run_params = self.params()
        self._worker = _Worker(self.state, self.sim, self._run_params, self._cancel)
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.chunk.connect(self.plots.append)
        self._worker.progress.connect(self._progress)
        self._worker.done.connect(self._done)
        self._worker.failed.connect(self._failed)
        self._thread.start()
        self._timer.start()

    def _progress(self, f, text):
        self.bar.setValue(int(1000 * max(0.0, min(f, 1.0))))
        self.msg.setText(text)

    def _finish(self):
        self._timer.stop()
        self.run_b.setEnabled(True)
        self.stop_b.setEnabled(False)
        if self._thread is not None:
            self._thread.quit()
            self._thread.wait()
            self._thread = None

    def _done(self, res: SimResult):
        self._finish()
        self.result = res
        self.bar.setValue(1000)
        nf = sum(c.status == "falha" for c in res.checks)
        na = sum(c.status == "atencao" for c in res.checks)
        tail = f" — {nf} falha(s), {na} atenção" if res.checks else ""
        self.msg.setText(f"terminado: {res.status}{tail}")
        # só os gráficos que têm dado nesta aeronave/neste caso
        specs = [s for s in self.sim.plots_for(self.state.aircraft, self._run_params) if _has_data(s, res)]
        self._set_plots(specs)
        self.plots.show_result(res)
        self._show_checks(res.checks)
        rows = list(res.summary.items())
        self.table.setRowCount(len(rows))
        for i, (k, v) in enumerate(rows):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(str(k)))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(format_value(v)))
        self.save_b.setEnabled(True)

    def _show_checks(self, checks):
        order = {"falha": 0, "atencao": 1, "ok": 2, "info": 3}
        self._checks = sorted(checks, key=lambda c: order.get(c.status, 9))
        for w in (self.diag_title, self.diag, self.diag_detail):
            w.setVisible(bool(checks))
        self.diag.setRowCount(len(self._checks))
        for i, c in enumerate(self._checks):
            txt, color = STATUS.get(c.status, (c.status, "#ffffff"))
            tip = "\n".join(x for x in (f"por quê: {c.why}" if c.why else "", f"o que fazer: {c.fix}" if c.fix else "",
                                         f"critério: {c.source}" if c.source else "") if x)
            for j, v in enumerate((txt, c.item, c.value, c.criterion)):
                it = QtWidgets.QTableWidgetItem(v)
                it.setToolTip(tip or v)
                if j == 0:
                    it.setBackground(QtGui.QColor(color))
                self.diag.setItem(i, j, it)
        self.diag.resizeRowsToContents()
        h = self.diag.horizontalHeader().height() + sum(self.diag.rowHeight(i) for i in range(len(self._checks))) + 4
        self.diag.setFixedHeight(h)
        self._detail(0 if self._checks else -1)

    def _detail(self, row):
        if not (0 <= row < len(self._checks)):
            self.diag_detail.setText("")
            return
        from html import escape as e
        c = self._checks[row]
        parts = [f"<b>{e(c.item)}</b>"]
        if c.why:
            parts.append(f"<b>por quê:</b> {e(c.why)}")
        if c.fix:
            parts.append(f"<b>o que fazer:</b> {e(c.fix)}")
        if c.source:
            parts.append(f"<b>critério:</b> {e(c.criterion)} — {e(c.source)}")
        self.diag_detail.setText("<br>".join(parts))

    def _failed(self, text):
        self._finish()
        self.plots.redraw()
        self.msg.setText(f"<span style='color:#b00'>{text}</span>")

    def export(self):
        if self.result is None:
            return
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Exportar", f"{self.sim.name}.xlsx",
                                                        "Excel (*.xlsx);;CSV (*.csv)")
        if path:
            self.msg.setText(export_result(self.result, path))


def _has_data(spec, res: SimResult) -> bool:
    if spec.source == "log":
        return res.log is not None and len(res.log) > 0
    name = spec.source.split(":", 1)[1]
    if name.endswith("*"):
        tabs = [v for k, v in res.series.items() if k.startswith(name[:-1])]
    else:
        tabs = [res.series.get(name)]
    return any(t and spec.x in t and any(y in t for y in spec.ys) for t in tabs)


def _tables(res: SimResult) -> dict:
    tables = {}
    if res.checks:
        tables["diagnostico"] = {k: [getattr(c, a) for c in res.checks] for k, a in
                                 (("estado", "status"), ("grupo", "group"), ("verificação", "item"), ("valor", "value"),
                                  ("limite", "criterion"), ("fonte do critério", "source"), ("por quê", "why"),
                                  ("o que fazer", "fix"))}
    if res.summary:
        tables["resumo"] = {"grandeza": list(res.summary), "valor": [format_value(v) for v in res.summary.values()]}
    tables.update(res.series)
    if res.log is not None and len(res.log):
        tables["registro"] = res.log.columns
    return tables


def export_result(res: SimResult, path: str) -> str:
    """.xlsx: uma aba por tabela (resumo, envelope, curvas, registro...); .csv: um arquivo por tabela"""
    tables = _tables(res)
    if path.lower().endswith(".xlsx"):
        from openpyxl import Workbook
        wb = Workbook()
        wb.remove(wb.active)
        used = set()
        for name, tab in tables.items():
            title = "".join(ch for ch in name if ch not in "[]:*?/\\")[:31] or "tabela"
            while title in used:
                title = title[:28] + f"_{len(used)}"
            used.add(title)
            sh = wb.create_sheet(title)
            keys = [k for k in tab if not k.startswith("_")]
            sh.append(keys)
            cols = [np.atleast_1d(tab[k]) for k in keys]
            for i in range(max(len(c) for c in cols)):
                sh.append([_cell(c[i]) if i < len(c) else None for c in cols])
        wb.save(path)
        return f"exportado em {path}"
    base = path[:-4] if path.lower().endswith(".csv") else path
    for name, tab in tables.items():
        keys = [k for k in tab if not k.startswith("_")]
        cols = [np.atleast_1d(tab[k]) for k in keys]
        safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in name)
        with open(f"{base}_{safe}.csv", "w", newline="") as f:
            w = csv.writer(f, delimiter=";")
            w.writerow(keys)
            for i in range(max(len(c) for c in cols)):
                w.writerow([format_value(c[i]) if i < len(c) else "" for c in cols])
    return f"exportado em {base}_*.csv"


def _cell(v):
    if isinstance(v, (np.floating, float)):
        return None if not np.isfinite(v) else float(v)
    if isinstance(v, (np.integer, int)):
        return int(v)
    return str(v)
