"""Aba genérica de uma simulação: formulário gerado pelos ParamSpec, botões rodar/parar,
progresso, resumo e gráficos em tempo real. Roda numa QThread; o núcleo devolve fatias
do registro que viram sinais Qt (thread-safe) e são desenhadas a ~15 Hz.
"""
from __future__ import annotations

import csv
import threading

import numpy as np
from PyQt6 import QtCore, QtWidgets

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


class SimulationTab(QtWidgets.QWidget):
    def __init__(self, state: AppState, sim: ISimulation, parent=None):
        super().__init__(parent)
        self.state, self.sim = state, sim
        self.inputs: dict[str, QtWidgets.QWidget] = {}
        self.result: SimResult | None = None
        self._thread: QtCore.QThread | None = None
        self._cancel = threading.Event()
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        QtWidgets.QHBoxLayout(self).addWidget(split)

        side = QtWidgets.QWidget()
        sv = QtWidgets.QVBoxLayout(side)
        d = QtWidgets.QLabel(f"<b>{sim.title}</b><br>{sim.description}")
        d.setWordWrap(True)
        sv.addWidget(d)
        form = QtWidgets.QFormLayout()
        for p in sim.parameters():
            w = self._input(p)
            self.inputs[p.key] = w
            lab = QtWidgets.QLabel(p.label + (f" ({p.unit})" if p.unit else ""))
            lab.setToolTip(p.help or p.key)
            form.addRow(lab, w)
        sv.addLayout(form)
        h = QtWidgets.QHBoxLayout()
        self.run_b = QtWidgets.QPushButton("▶ Rodar")
        self.stop_b = QtWidgets.QPushButton("■ Parar")
        self.save_b = QtWidgets.QPushButton("Exportar CSV…")
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
        sv.addWidget(self.table, 1)
        split.addWidget(side)

        self.plots = LivePlots(sim.plots())
        split.addWidget(self.plots)
        split.setStretchFactor(0, 2)
        split.setStretchFactor(1, 8)
        split.setSizes([330, 1100])

        self.run_b.clicked.connect(self.start)
        self.stop_b.clicked.connect(self._cancel.set)
        self.save_b.clicked.connect(self.export)
        self._timer = QtCore.QTimer(self)
        self._timer.setInterval(66)
        self._timer.timeout.connect(self.plots.redraw)

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
            w.setDecimals(4)
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
        self.plots.clear()
        self.table.setRowCount(0)
        self.msg.setText("rodando…")
        self.run_b.setEnabled(False)
        self.stop_b.setEnabled(True)
        self._thread = QtCore.QThread(self)
        self._worker = _Worker(self.state, self.sim, self.params(), self._cancel)
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
        self.msg.setText(f"terminado: {res.status}")
        self.plots.show_result(res)
        rows = list(res.summary.items())
        self.table.setRowCount(len(rows))
        for i, (k, v) in enumerate(rows):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(str(k)))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(format_value(v)))
        self.save_b.setEnabled(True)

    def _failed(self, text):
        self._finish()
        self.plots.redraw()
        self.msg.setText(f"<span style='color:#b00'>{text}</span>")

    def export(self):
        if self.result is None:
            return
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Exportar", f"{self.sim.name}.csv", "CSV (*.csv)")
        if not path:
            return
        base = path[:-4] if path.endswith(".csv") else path
        tables = dict(self.result.series)
        if self.result.log is not None and len(self.result.log):
            tables["registro"] = self.result.log.columns
        for name, tab in tables.items():
            keys = list(tab)
            n = max(len(np.atleast_1d(tab[k])) for k in keys)
            with open(f"{base}_{name.replace(' ', '_').replace('@', '')}.csv", "w", newline="") as f:
                w = csv.writer(f, delimiter=";")
                w.writerow(keys)
                for i in range(n):
                    w.writerow([format_value(np.atleast_1d(tab[k])[i]) if i < len(np.atleast_1d(tab[k])) else ""
                                for k in keys])
        self.msg.setText(f"exportado em {base}_*.csv")
