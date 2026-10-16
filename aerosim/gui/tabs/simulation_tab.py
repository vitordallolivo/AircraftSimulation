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
from ..widgets.checks_panel import STATUS, ChecksPanel  # noqa: F401  (STATUS: compatibilidade)
from ..widgets.plots import LivePlots, format_value
from ..widgets.param_slider import HELP_MARK


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
        split.setHandleWidth(10)
        split.setChildrenCollapsible(False)
        split.setStyleSheet("QSplitter::handle { background: #c9d3e0; } QSplitter::handle:hover { background: #7f9cc4; }")
        QtWidgets.QHBoxLayout(self).addWidget(split)

        side = QtWidgets.QWidget()
        sv = QtWidgets.QVBoxLayout(side)
        d = QtWidgets.QLabel(f"<b>{sim.title}</b>" + (HELP_MARK if sim.description else ""))
        d.setToolTip(sim.description)                     # texto longo: só no passar do mouse
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
        sv.addStretch(1)
        split.addWidget(side)

        # direita: uma rolagem só — gráficos grandes (legenda embaixo de cada um) e, no fim, o diagnóstico
        self.right_scroll = QtWidgets.QScrollArea()
        self.right_scroll.setWidgetResizable(True)
        self.right_scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        inner = QtWidgets.QWidget()
        self.right = QtWidgets.QVBoxLayout(inner)
        if getattr(sim, "show_aircraft", False):
            # o avião da sprint em cima (com a troca entre aviões abertos); os gráficos rolam embaixo
            from ..widgets.aircraft_panel import AircraftPanel
            self.aircraft_panel = AircraftPanel(state, height=230)
            self.right.addWidget(self.aircraft_panel)
        self.plots = LivePlots([])
        self.right.addWidget(self.plots)
        self.checks_panel = ChecksPanel()        # diagnóstico e resumo: no fim da rolagem
        self.diag, self.table = self.checks_panel.diag, self.checks_panel.table
        self.right.addWidget(self.checks_panel)
        self.right.addStretch(1)
        self.right_scroll.setWidget(inner)
        split.addWidget(self.right_scroll)
        split.setStretchFactor(0, 2)
        split.setStretchFactor(1, 8)
        split.setSizes([340, 1000])          # cabe em 1366 × 768

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
        state.changed.connect(lambda r: self._show_cached() if r == "load" else None)
        self._loading = False
        self._shown_sig = None               # de que avião é o resultado na tela
        self.reconfigure()
        state.register(f"aba:{sim.name}", self.params, self._put)       # entra no Ctrl+Z
        self._show_cached()                  # o que já rodou com este avião (guardado no projeto)

    def _touched(self, *_):
        if not self._loading:
            self.state.touch()

    def _put(self, values: dict) -> None:
        """desfazer: recoloca os valores (primeiro os que refazem o formulário, ex.: modo)"""
        self._loading = True
        try:
            first = [k for k in values if k in self.inputs and isinstance(self.inputs[k], QtWidgets.QComboBox)]
            for k in first:
                self._set(self.inputs[k], values[k])
            self._specs_sig = None if first else self._specs_sig
            self.reconfigure()
            for k, v in values.items():
                if k in self.inputs:
                    self._set(self.inputs[k], v)
        finally:
            self._loading = False

    # ------------------------------------------------------------------ montagem pela aeronave
    def reconfigure(self) -> None:
        """refaz o formulário e os gráficos se a aeronave (ou uma escolha como a norma) pede outros,
        mantendo os valores digitados"""
        if self._thread is not None:
            return
        loading, self._loading = self._loading, True
        try:
            self._reconfigure()
        finally:
            self._loading = loading

    def _reconfigure(self) -> None:
        ac = self.state.aircraft
        old = self.params() if self.inputs else {}
        specs = self.sim.parameters_for(ac, old)
        sig = tuple((p.key, p.label, p.kind, tuple(p.choices), p.group,
                     tuple(r.get("item") for r in p.default) if p.kind == "table" and not p.bound else ())
                    for p in specs)
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
                if p.key in old and not p.bound:             # tabela ligada à aeronave: vem dela
                    self._set(w, old[p.key])
                self.inputs[p.key] = w
                if p.help:
                    w.setToolTip(p.help)
                if isinstance(w, QtWidgets.QCheckBox):        # o texto vai na própria caixa: linha inteira
                    w.setText(p.label + (" ⓘ" if p.help else ""))
                    self.form.addRow(w)
                else:
                    lab = QtWidgets.QLabel(p.label + (f" ({p.unit})" if p.unit else "") + (HELP_MARK if p.help else ""))
                    lab.setWordWrap(True)
                    lab.setToolTip(p.help)
                    if isinstance(w, TableInput):
                        self.form.addRow(lab)
                        self.form.addRow(w)
                        w.edited.connect(self._commit)
                    else:
                        self.form.addRow(lab, w)
                for sg in ("currentTextChanged", "toggled", "valueChanged", "textEdited", "edited"):
                    if hasattr(w, sg):
                        getattr(w, sg).connect(self._touched)
                        break
                if p.rebuild:
                    sig_ = w.currentTextChanged if isinstance(w, QtWidgets.QComboBox) else (
                        w.toggled if isinstance(w, QtWidgets.QCheckBox) else None)
                    if sig_ is not None:
                        sig_.connect(lambda *_: QtCore.QTimer.singleShot(0, self.reconfigure))
            self._specs_sig = sig
        for p in specs:                     # tabelas ligadas à aeronave (ex.: trajetória): seguem a configuração
            w = self.inputs.get(p.key)
            if isinstance(w, TableInput) and p.bound and _norm(w.rows()) != _norm(p.default):
                w.set_rows(p.default)
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

    def _commit(self):
        """o que o formulário edita da aeronave (ex.: trajetória) vai para a configuração"""
        if self.sim.commit(self.state.aircraft, self.params()):
            self.state.notify("mission")

    @staticmethod
    def _set(w, v):
        try:
            if isinstance(w, TableInput):
                w.set_rows(v)
            elif isinstance(w, QtWidgets.QCheckBox):
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
        if p.kind == "table":
            w = TableInput(p.columns)
            w.set_rows(p.default)
        elif p.kind == "bool":
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
        elif p.kind == "file":                      # caminho, com o botão de procurar dentro do campo
            w = QtWidgets.QLineEdit(str(p.default))
            w.setPlaceholderText("arquivo…")
            act = w.addAction(self.style().standardIcon(QtWidgets.QStyle.StandardPixmap.SP_DirOpenIcon),
                              QtWidgets.QLineEdit.ActionPosition.TrailingPosition)
            act.setToolTip("procurar o arquivo")

            def pick(_=False, w=w, p=p):
                path, _f = QtWidgets.QFileDialog.getOpenFileName(self, p.label, w.text(),
                                                                 "polar (*.txt *.csv *.dat);;todos (*)")
                if path:
                    w.setText(path)
            act.triggered.connect(pick)
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
            if isinstance(w, TableInput):
                out[k] = w.rows()
            elif isinstance(w, QtWidgets.QCheckBox):
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
        self.checks_panel.show_checks([])
        self.checks_panel.show_summary({})
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

    def _show_cached(self) -> None:
        """mostra o resultado guardado no projeto para o avião atual (com os parâmetros daquela rodada); sem
        ele, e com o resultado de outro avião na tela, limpa"""
        if self._thread is not None:
            return
        sig = self.state.aircraft_sig(self.state.aircraft)
        if sig == self._shown_sig:
            return
        e = self.state.cached_run(self.sim.name, self.state.aircraft)
        if e is None:
            if self.result is not None:
                self.result = None
                self.plots.clear()
                self.checks_panel.show_checks([])
                self.checks_panel.show_summary({})
                self.save_b.setEnabled(False)
                self.bar.setValue(0)
                self.msg.setText("")
            self._shown_sig = sig
            return
        from aerosim.interfaces.result_io import _dec, result_from_dict
        try:
            res = result_from_dict(e["result"])
            params = _dec(e.get("params") or {})
        except Exception:
            return
        self._put(params)
        self._run_params = self.params()
        self._show_result(res)
        self._shown_sig = sig
        self.msg.setText(f"guardado no projeto (rodou em {e.get('when', '?').replace('T', ' ')}) — ▶ Rodar refaz")

    def _show_result(self, res: SimResult) -> None:
        self.result = res
        self.bar.setValue(1000)
        specs = [s for s in self.sim.plots_for(self.state.aircraft, self._run_params) if _has_data(s, res)]
        self._set_plots(specs)
        self.plots.show_result(res)
        self.checks_panel.show_checks(res.checks)
        self.checks_panel.show_summary(res.summary)
        self.save_b.setEnabled(True)

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
        nf = sum(c.status == "falha" for c in res.checks)
        na = sum(c.status == "atencao" for c in res.checks)
        tail = f" — {nf} falha(s), {na} atenção" if res.checks else ""
        self._show_result(res)               # só os gráficos que têm dado nesta aeronave/neste caso
        self.msg.setText(f"terminado: {res.status}{tail}")
        try:                                 # guarda no projeto: ao abrir de novo, aparece sem rodar
            # o avião como ficou depois de rodar (a Missão grava a trajetória nele): é ele que vai para o projeto
            self._shown_sig = self.state.aircraft_sig(self.state.aircraft)
            self.state.remember_run(self.sim.name, self.state.aircraft, self._run_params, res, self._shown_sig)
        except Exception as ex:
            self.msg.setText(self.msg.text() + f" (não guardei no projeto: {ex})")

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


def _norm(rows) -> list:
    return [{k: (round(float(v), 6) if isinstance(v, (int, float)) else ("" if v is None else str(v)))
             for k, v in r.items()} for r in rows or []]


class TableInput(QtWidgets.QWidget):
    """tabela editável (uma linha por item; colunas numéricas, texto ou listas de opções) + / −"""
    edited = QtCore.pyqtSignal()

    def __init__(self, columns):
        super().__init__()
        helps = [c[3] if len(c) > 3 else "" for c in columns]        # 4º item: dica do cabeçalho
        self.columns = [tuple(c[:3]) for c in columns]
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        self.t = QtWidgets.QTableWidget(0, len(self.columns))
        for i, (c, hp) in enumerate(zip(self.columns, helps)):
            it = QtWidgets.QTableWidgetItem(c[1] + (" ⓘ" if hp else ""))
            if hp:
                it.setToolTip(hp)
            self.t.setHorizontalHeaderItem(i, it)
        self.t.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.t.horizontalHeader().setStretchLastSection(True)
        self.t.setMinimumHeight(240)
        self.t.itemChanged.connect(lambda *_: self.edited.emit())
        v.addWidget(self.t)
        self.fixed = any(c[2] == "label" for c in self.columns)      # linhas fixas: sem + / −
        if self.fixed:
            self.t.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
            self.t.verticalHeader().setVisible(False)
            self.t.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
            self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred, QtWidgets.QSizePolicy.Policy.Fixed)
            return
        h = QtWidgets.QHBoxLayout()
        for txt, fn in (("+ adicionar linha", self._add), ("− remover a selecionada", self._rem),
                        ("↑", lambda: self._move(-1)), ("↓", lambda: self._move(1))):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            h.addWidget(b)
        v.addLayout(h)

    def _cell(self, r, c, val):
        key, _, kind = self.columns[c]
        if isinstance(kind, (tuple, list)):
            cb = QtWidgets.QComboBox()
            cb.addItems([str(o) for o in kind])
            cb.setCurrentText(str(val))
            cb.currentTextChanged.connect(lambda *_: self.edited.emit())
            self.t.setCellWidget(r, c, cb)
        else:
            txt = "" if val is None else (f"{val:g}" if isinstance(val, (int, float)) else str(val))
            it = QtWidgets.QTableWidgetItem(txt)
            if kind == "label":
                it.setFlags(it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
                f = it.font()
                f.setBold(True)
                it.setFont(f)
            self.t.setItem(r, c, it)

    def set_rows(self, rows):
        self.t.blockSignals(True)
        self.t.setRowCount(0)
        for row in rows or []:
            r = self.t.rowCount()
            self.t.insertRow(r)
            for c, (key, _, _) in enumerate(self.columns):
                self._cell(r, c, row.get(key, ""))
        self.t.blockSignals(False)
        if self.fixed:                       # altura justa para as linhas
            self.t.setMinimumHeight(0)
            self.t.setFixedHeight(self.t.horizontalHeader().height() + 6 +
                                  sum(self.t.rowHeight(i) for i in range(self.t.rowCount())))

    def rows(self) -> list[dict]:
        out = []
        for r in range(self.t.rowCount()):
            row = {}
            for c, (key, _, kind) in enumerate(self.columns):
                w = self.t.cellWidget(r, c)
                if w is not None:
                    row[key] = w.currentText()
                    continue
                it = self.t.item(r, c)
                txt = it.text().strip() if it else ""
                if kind == "float":
                    try:
                        row[key] = float(txt.replace(",", ".")) if txt else None
                    except ValueError:
                        row[key] = None
                else:
                    row[key] = txt
            out.append(row)
        return out

    def _add(self):
        rows = self.rows()
        r = self.t.currentRow()
        new = dict(rows[r]) if 0 <= r < len(rows) else (dict(rows[-1]) if rows else {})
        rows.insert((r + 1) if r >= 0 else len(rows), new)
        self.set_rows(rows)
        self.edited.emit()

    def _rem(self):
        r = self.t.currentRow()
        rows = self.rows()
        if 0 <= r < len(rows) and len(rows) > 1:
            rows.pop(r)
            self.set_rows(rows)
            self.edited.emit()

    def _move(self, d):
        r = self.t.currentRow()
        rows = self.rows()
        if 0 <= r < len(rows) and 0 <= r + d < len(rows):
            rows[r], rows[r + d] = rows[r + d], rows[r]
            self.set_rows(rows)
            self.t.setCurrentCell(r + d, 0)
            self.edited.emit()


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
    # séries só de estilo (linhas e faixas de referência: _hline, _vline, _vspan) não têm coluna para exportar
    tables.update({k: v for k, v in res.series.items() if any(not str(c).startswith("_") for c in v)})
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
