"""O avião da sprint nas abas: barra para trocar entre os aviões abertos (◀ nome ▶, + variante,
× fechar) e o 3D (só para ver; editar é na aba Montagem), com uma linha de resumo.

`FleetBar` sozinha também serve à Montagem (que tem o próprio 3D editável).
"""
from __future__ import annotations

from PyQt6 import QtCore, QtWidgets

from ..state import AppState
from .view3d import AircraftView


class FleetBar(QtWidgets.QWidget):
    """◀ [avião 2/3 ▾] ▶  + variante  × fechar — muda `state.current` (todas as abas acompanham)"""

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        self.prev = QtWidgets.QToolButton()
        self.prev.setText("◀")
        self.prev.setToolTip("avião anterior")
        self.combo = QtWidgets.QComboBox()
        self.combo.setSizeAdjustPolicy(QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.combo.setMinimumContentsLength(14)
        self.combo.setToolTip("aviões abertos: todas as abas mostram e rodam o escolhido")
        self.next = QtWidgets.QToolButton()
        self.next.setText("▶")
        self.next.setToolTip("próximo avião")
        self.add_b = QtWidgets.QToolButton()
        self.add_b.setText("＋ variante")
        self.add_b.setToolTip("abre uma cópia deste avião para variar a partir dele")
        self.close_b = QtWidgets.QToolButton()
        self.close_b.setText("×")
        self.close_b.setToolTip("fecha este avião (os outros continuam abertos)")
        for w in (self.prev, self.combo, self.next, self.add_b, self.close_b):
            h.addWidget(w)
        h.setStretch(1, 1)
        self.prev.clicked.connect(lambda: state.select(state.current - 1))
        self.next.clicked.connect(lambda: state.select(state.current + 1))
        self.combo.activated.connect(state.select)
        self.add_b.clicked.connect(lambda: state.add())
        self.close_b.clicked.connect(lambda: state.close())
        state.changed.connect(self._on_state)
        self.refresh()

    def _on_state(self, reason):
        if reason in ("load", "name") or self.combo.count() != len(self.state.fleet):
            self.refresh()
        elif self.combo.itemText(self.state.current) != self._label(self.state.current):
            self.refresh()

    def _label(self, i: int) -> str:
        n = len(self.state.fleet)
        return f"{self.state.fleet[i].name}" + (f"  ({i + 1}/{n})" if n > 1 else "")

    def refresh(self):
        self.combo.blockSignals(True)
        self.combo.clear()
        for i in range(len(self.state.fleet)):
            self.combo.addItem(self._label(i))
        self.combo.setCurrentIndex(self.state.current)
        self.combo.blockSignals(False)
        n = len(self.state.fleet)
        self.prev.setEnabled(self.state.current > 0)
        self.next.setEnabled(self.state.current < n - 1)
        self.close_b.setEnabled(n > 1)


class AircraftPanel(QtWidgets.QWidget):
    """barra de troca + 3D só de ver + resumo (massa, envergadura, área); refaz o 3D quando a aba aparece"""

    def __init__(self, state: AppState, height: int = 260, parent=None):
        super().__init__(parent)
        self.state = state
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        self.bar = FleetBar(state)
        v.addWidget(self.bar)
        self.view = AircraftView()
        self.view.move_mode = False
        self.view.setMinimumHeight(height)
        self.view.setMaximumHeight(int(height * 1.6))
        v.addWidget(self.view, 1)
        self.info = QtWidgets.QLabel()
        self.info.setStyleSheet("color: #555; font-size: 11px")
        self.info.setWordWrap(True)
        v.addWidget(self.info)
        self._dirty = True
        self._timer = QtCore.QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._rebuild)
        state.changed.connect(self._on_state)

    def _on_state(self, reason):
        self._dirty = True
        if self.isVisible():
            self._timer.start(120 if reason != "load" else 0)

    def showEvent(self, e):
        super().showEvent(e)
        if self._dirty:
            self._timer.start(0)

    def _rebuild(self):
        ac = self.state.aircraft
        if self.view.aircraft is not ac:
            self.view.set_aircraft(ac)
        else:
            self.view.rebuild()
        self._dirty = False
        self.info.setText(summary_line(ac))


def summary_line(ac) -> str:
    """uma linha: massa, envergadura e área da asa, superfícies e motores"""
    parts = []
    try:
        S, c, b = ac.references()
        parts.append(f"b = {b:.2f} m · S = {S:.3f} m² · c = {c:.3f} m")
    except Exception:
        pass
    try:
        from aerosim.model.massprops import dry_mass
        mp = dry_mass(ac)
        x = float(mp["cg"][0])
        try:                                         # xCG em % da CMA (e em metros, o que o modelo usa)
            from aerosim.model.universal import build_model
            pc = f"{100 * build_model(ac).mac_frac(x):.1f} % CMA ({x:.3f} m)"
        except Exception:
            pc = f"{x:.3f} m"
        parts.append(f"massa vazia = {mp['m']:.2f} kg · xCG = {pc}")
    except Exception:
        pass
    surf = [s.name for s in ac.surfaces if s.enabled]
    parts.append(f"{len(surf)} superfície(s), {sum(1 for u in ac.propulsion if u.enabled)} motor(es)")
    return "   ·   ".join(parts)
