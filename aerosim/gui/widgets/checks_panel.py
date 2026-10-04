"""Diagnóstico (estado, verificação, valor, limite — clique numa linha para o porquê e o que mudar) e a
tabela de resultados (grandeza, valor). Usado pelas abas de simulação e pelas etapas da sprint."""
from __future__ import annotations

from html import escape

from PyQt6 import QtCore, QtGui, QtWidgets

from .param_slider import HELP_MARK
from .plots import format_value

STATUS = {"ok": ("✔ OK", "#d9f2e6"), "atencao": ("⚠ ATENÇÃO", "#fff1cc"), "falha": ("✖ FALHA", "#fbdada"),
          "info": ("ℹ INFO", "#e8eef8")}


def _fixed_table(cols: int, labels: list[str]) -> QtWidgets.QTableWidget:
    t = QtWidgets.QTableWidget(0, cols)
    t.setHorizontalHeaderLabels(labels)
    t.verticalHeader().setVisible(False)
    t.setWordWrap(True)
    t.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    t.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    t.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
    return t


class ChecksPanel(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        self.diag_title = QtWidgets.QLabel("<b>Diagnóstico</b>" + HELP_MARK)
        self.diag_title.setToolTip("clique numa linha para ver o porquê e o que mudar")
        self.diag = _fixed_table(4, ["estado", "verificação", "valor", "limite"])
        hh = self.diag.horizontalHeader()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        for i in range(1, 4):
            hh.setSectionResizeMode(i, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.diag_detail = QtWidgets.QLabel()
        self.diag_detail.setWordWrap(True)
        self.diag_detail.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.diag.currentCellChanged.connect(lambda r, *_: self._detail(r))
        self.table_title = QtWidgets.QLabel("<b>Resultados</b>")
        self.table = _fixed_table(2, ["grandeza", "valor"])
        self.table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        for w in (self.diag_title, self.diag, self.diag_detail, self.table_title, self.table):
            w.hide()
            v.addWidget(w)
        self._checks = []

    def show_checks(self, checks) -> None:
        order = {"falha": 0, "atencao": 1, "ok": 2, "info": 3}
        self._checks = sorted(checks, key=lambda c: order.get(c.status, 9))
        for w in (self.diag_title, self.diag, self.diag_detail):
            w.setVisible(bool(checks))
        self.diag.setRowCount(len(self._checks))
        for i, c in enumerate(self._checks):
            txt, color = STATUS.get(c.status, (c.status, "#ffffff"))
            tip = "\n".join(x for x in (f"por quê: {c.why}" if c.why else "", f"o que fazer: {c.fix}" if c.fix else "",
                                         f"critério: {c.source}" if c.source else "") if x)
            for j, val in enumerate((txt, c.item, c.value, c.criterion)):
                it = QtWidgets.QTableWidgetItem(val)
                it.setToolTip(tip or val)
                if j == 0:
                    it.setBackground(QtGui.QColor(color))
                self.diag.setItem(i, j, it)
        self.diag.resizeRowsToContents()
        h = self.diag.horizontalHeader().height() + sum(self.diag.rowHeight(i) for i in range(len(self._checks))) + 4
        self.diag.setFixedHeight(h)
        self._detail(0 if self._checks else -1)

    def clear(self) -> None:
        self.show_checks([])
        self.show_summary({})

    def show_summary(self, summary: dict) -> None:
        rows = list(summary.items())
        self.table.setRowCount(len(rows))
        for i, (k, val) in enumerate(rows):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(str(k)))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(format_value(val)))
        self.table.resizeRowsToContents()
        self.table.setFixedHeight(self.table.horizontalHeader().height() + 4 +
                                  sum(self.table.rowHeight(i) for i in range(len(rows))))
        for w in (self.table_title, self.table):
            w.setVisible(bool(rows))

    def _detail(self, row) -> None:
        if not (0 <= row < len(self._checks)):
            self.diag_detail.setText("")
            return
        c = self._checks[row]
        parts = [f"<b>{escape(c.item)}</b>"]
        if c.why:
            parts.append(f"<b>por quê:</b> {escape(c.why)}")
        if c.fix:
            parts.append(f"<b>o que fazer:</b> {escape(c.fix)}")
        if c.source:
            parts.append(f"<b>critério:</b> {escape(c.criterion)} — {escape(c.source)}")
        self.diag_detail.setText("<br>".join(parts))
