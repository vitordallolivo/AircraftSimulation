"""Tabela de dimensões a partir do CG de projeto (`aerosim.design.dims`): grupo, item, Δx, Δy, Δz e o valor "de
planilha" (x_TDP, x_TDN, braços, alturas ao chão...); a nota de cada linha fica na dica."""
from __future__ import annotations

from PyQt6 import QtCore, QtGui, QtWidgets

from aerosim.design.dims import dimensions

from .param_slider import HELP_MARK

HEAD = ("grupo", "item", "Δx (m)", "Δy (m)", "Δz (m)", "valor")


class DimsTable(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        t = QtWidgets.QLabel("<b>Dimensões a partir do CG de projeto</b>" + HELP_MARK)
        t.setToolTip("posições em relação ao CG de projeto, eixos do corpo: Δx + à frente, Δy + à direita, Δz + para "
                     "baixo. 'valor' é a grandeza como na planilha (x_TDP + atrás do CG, x_TDN + à frente, braço da "
                     "cauda, alturas ao chão...). O chão é o das rodas principais, avião nivelado. Passe o mouse "
                     "numa linha para ver o que ela é.")
        v.addWidget(t)
        self.table = QtWidgets.QTableWidget(0, len(HEAD))
        self.table.setHorizontalHeaderLabels(HEAD)
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        v.addWidget(self.table)
        self.rows: list = []

    def show_aircraft(self, ac, cg=None) -> None:
        try:
            self.rows = dimensions(ac, cg)
        except Exception as ex:          # avião incompleto (sem asa, sem trem...): mostra o que der
            self.rows = [("—", f"não deu para medir: {ex}", None, None, None, None, "")]
        f = lambda v: "" if v is None else f"{v:+.3f}"
        bold = QtGui.QFont()
        bold.setBold(True)
        self.table.setRowCount(len(self.rows))
        for r, (g, item, dx, dy, dz, val, note) in enumerate(self.rows):
            for c, txt in enumerate((g, item, f(dx), f(dy), f(dz), "" if val is None else f"{val:.3f}")):
                it = QtWidgets.QTableWidgetItem(txt)
                it.setToolTip(note)
                if c == 5:
                    it.setFont(bold)
                if c >= 2:
                    it.setTextAlignment(QtCore.Qt.AlignmentFlag.AlignRight | QtCore.Qt.AlignmentFlag.AlignVCenter)
                self.table.setItem(r, c, it)
        self.table.resizeRowsToContents()
        self.table.setFixedHeight(self.table.horizontalHeader().height() + 4 +
                                  sum(self.table.rowHeight(i) for i in range(len(self.rows))))

    def value(self, item: str):
        return next((r[5] for r in self.rows if r[1] == item), None)
