"""Slider + campo numérico sincronizados, e um formulário automático para dataclasses."""
from __future__ import annotations

import dataclasses
import typing

from PyQt6 import QtCore, QtWidgets

from aerosim.manager.form_meta import (CHOICES, CONTROL_KINDS, EVENT_KINDS, GEAR_KINDS, HELP, LABELS,  # noqa: F401
                                         LEG_KINDS, RANGES, UNITS)


def _decimals(step: float) -> int:
    s = f"{step:.10f}".rstrip("0")
    return max(0, len(s.split(".")[1]) if "." in s else 0)


class ParamSlider(QtWidgets.QWidget):
    """rótulo | slider | campo — arrastar ou digitar"""
    valueChanged = QtCore.pyqtSignal(float)
    RES = 1000

    def __init__(self, label: str, value: float, minimum: float = 0.0, maximum: float = 1.0, step: float = 0.01,
                 unit: str = "", parent=None):
        super().__init__(parent)
        self._lo, self._hi = minimum, maximum
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.label = QtWidgets.QLabel(label)
        self.label.setMinimumWidth(90)
        self.label.setToolTip(label)
        self.slider = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal)
        self.slider.setRange(0, self.RES)
        self.spin = QtWidgets.QDoubleSpinBox()
        self.spin.setDecimals(min(_decimals(step) + 1, 6))
        self.spin.setRange(minimum, maximum)
        self.spin.setSingleStep(step)
        self.spin.setSuffix(f" {unit}" if unit else "")
        self.spin.setKeyboardTracking(False)
        self.spin.setMinimumWidth(92)
        lay.addWidget(self.label, 3)
        lay.addWidget(self.slider, 4)
        lay.addWidget(self.spin, 3)
        self._block = False
        self.setValue(value)
        self.slider.valueChanged.connect(self._from_slider)
        self.spin.valueChanged.connect(self._from_spin)

    def value(self) -> float:
        return self.spin.value()

    def setValue(self, v: float) -> None:
        self._block = True
        if v < self._lo:
            self._lo = v
        if v > self._hi:
            self._hi = v
        self.spin.setValue(v)
        self.slider.setValue(self._to_pos(v))
        self._block = False

    def _to_pos(self, v):
        span = self._hi - self._lo
        return int(round((v - self._lo) / span * self.RES)) if span > 0 else 0

    def _from_slider(self, pos):
        if self._block:
            return
        v = self._lo + (self._hi - self._lo) * pos / self.RES
        self._block = True
        self.spin.setValue(v)
        self._block = False
        self.valueChanged.emit(self.spin.value())

    def _from_spin(self, v):
        if self._block:
            return
        self._block = True
        if v < self._lo or v > self._hi:
            self._lo, self._hi = min(self._lo, v), max(self._hi, v)
        self.slider.setValue(self._to_pos(v))
        self._block = False
        self.valueChanged.emit(v)


class NumberField(QtWidgets.QWidget):
    """rótulo | campo numérico (digitar, setas ou roda do mouse com o campo em foco) — sem slider"""
    valueChanged = QtCore.pyqtSignal(float)

    def __init__(self, label: str, value: float, minimum: float = -1e9, maximum: float = 1e9, step: float = 0.01,
                 unit: str = "", parent=None):
        super().__init__(parent)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.label = QtWidgets.QLabel(label)
        self.label.setWordWrap(True)
        self.label.setToolTip(label)
        self.spin = _Spin()
        self.spin.setMinimumWidth(105)
        self.spin.setDecimals(min(_decimals(step) + 1, 6))
        self.spin.setRange(-1e9, 1e9)
        self.spin.setSingleStep(step)
        self.spin.setSuffix(f" {unit}" if unit else "")
        self.spin.setKeyboardTracking(False)
        self.spin.setValue(value)
        lay.addWidget(self.label, 5)
        lay.addWidget(self.spin, 4)
        self.spin.valueChanged.connect(self.valueChanged.emit)

    def value(self) -> float:
        return self.spin.value()

    def setValue(self, v: float) -> None:
        self.spin.blockSignals(True)
        self.spin.setValue(v)
        self.spin.blockSignals(False)


class _Spin(QtWidgets.QDoubleSpinBox):
    """não rouba a roda do mouse da rolagem do painel: só muda o valor se estiver em foco"""

    def __init__(self):
        super().__init__()
        self.setFocusPolicy(QtCore.Qt.FocusPolicy.StrongFocus)

    def wheelEvent(self, e):
        if self.hasFocus():
            super().wheelEvent(e)
        else:
            e.ignore()


HELP_MARK = " <span style='color:#1f77b4'>ⓘ</span>"


def _hint(w, text: str) -> None:
    """ⓘ no rótulo, explicação no passar do mouse"""
    w.setToolTip(text)
    if isinstance(w, QtWidgets.QCheckBox):
        w.setText(w.text() + " ⓘ")
        return
    lb = getattr(w, "label", None) or w.findChild(QtWidgets.QLabel)
    if lb is not None:
        lb.setTextFormat(QtCore.Qt.TextFormat.RichText)
        lb.setText(lb.text() + HELP_MARK)
        lb.setToolTip(text)


class DataclassForm(QtWidgets.QWidget):
    """formulário gerado a partir dos campos de uma dataclass (edita o objeto no lugar)"""
    changed = QtCore.pyqtSignal(str)

    def __init__(self, obj, exclude: tuple = (), choices: dict | None = None, parent=None, editable: tuple = ()):
        """rótulo, unidade, dica, opções e passo vêm dos metadados do campo (`aerosim.design.fields.F`) ou,
        sem eles, dos dicionários deste módulo; `choices` (por campo) manda sobre os dois; em `editable` a
        lista de opções aceita texto livre"""
        super().__init__(parent)
        self.obj = obj
        self.choices = dict(CHOICES)
        self.choices.update(choices or {})
        self._given = dict(choices or {})
        self._editable = set(editable)
        self.widgets: dict[str, QtWidgets.QWidget] = {}
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        hints = typing.get_type_hints(type(obj))
        for f in dataclasses.fields(obj):
            if f.name in exclude:
                continue
            tp = hints[f.name]
            v = getattr(obj, f.name)
            meta = dict(f.metadata)
            w = self._make(f.name, tp, v, meta)
            if w is not None:
                tip = meta.get("help") or HELP.get(f.name)
                if tip:
                    _hint(w, tip)
                lay.addWidget(w)
                self.widgets[f.name] = w

    def _make(self, name, tp, v, meta=None):
        meta = meta or {}
        label = meta.get("label") or LABELS.get(name, name)
        opt = typing.get_origin(tp) in (typing.Union, getattr(__import__("types"), "UnionType", None))
        base = [a for a in typing.get_args(tp) if a is not type(None)][0] if opt else tp
        if dataclasses.is_dataclass(base):
            box = QtWidgets.QGroupBox(label)
            inner = DataclassForm(v, exclude=("coords",), choices=self._given)
            inner.changed.connect(lambda k, n=name: self.changed.emit(f"{n}.{k}"))
            QtWidgets.QVBoxLayout(box).addWidget(inner)
            return box
        if base is bool:
            w = QtWidgets.QCheckBox(label)
            w.setChecked(bool(v))
            w.toggled.connect(lambda val, n=name: self._set(n, bool(val)))
            return w
        if base is str:
            ch = self._given.get(name) or meta.get("choices") or self.choices.get(name)
            if ch:
                w = QtWidgets.QComboBox()
                w.addItems(list(ch))
                if name in self._editable:
                    w.setEditable(True)
                    w.setCurrentText(v)
                elif v in ch:
                    w.setCurrentText(v)
                w.currentTextChanged.connect(lambda val, n=name: self._set(n, val))
            else:
                w = QtWidgets.QLineEdit(v)
                w.editingFinished.connect(lambda n=name, ww=w: self._set(n, ww.text()))
            return self._row(label, w)
        if base is int:
            w = QtWidgets.QSpinBox()
            w.setRange(-1000000, 1000000)
            w.setValue(int(v))
            w.valueChanged.connect(lambda val, n=name: self._set(n, int(val)))
            return self._row(label, w)
        if base is float:
            if opt:      # sobrescrita opcional: caixa "auto" + campo
                return self._optional(name, label, v)
            lo, hi, st, un = RANGES.get(name, (min(0.0, v * 2) if v else -1.0, max(1.0, v * 2) if v else 1.0, 0.01,
                                               UNITS.get(name, "")))
            mn, mx = -1e9, 1e9
            if "range" in meta:
                r0, r1, r2 = meta["range"]
                mn, mx, st = (r0 if r0 is not None else mn), (r1 if r1 is not None else mx), (r2 or st)
            if "label" in meta:
                un = meta.get("unit", "")
            w = NumberField(label, float(v), minimum=mn, maximum=mx, step=st, unit=un)
            w.valueChanged.connect(lambda val, n=name: self._set(n, float(val)))
            return w
        return None          # listas: editores próprios

    def _optional(self, name, label, v):
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        auto = QtWidgets.QCheckBox(f"{label}: auto")
        spin = QtWidgets.QDoubleSpinBox()
        spin.setMinimumWidth(105)
        spin.setDecimals(5)
        spin.setRange(-1e6, 1e6)
        spin.setSingleStep(0.01)
        auto.setChecked(v is None)
        spin.setEnabled(v is not None)
        spin.setValue(0.0 if v is None else float(v))
        auto.toggled.connect(lambda on: (spin.setEnabled(not on), self._set(name, None if on else spin.value())))
        spin.valueChanged.connect(lambda val: self._set(name, float(val)) if not auto.isChecked() else None)
        h.addWidget(auto, 3)
        h.addWidget(spin, 2)
        return box

    def _row(self, label, w):
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        lb = QtWidgets.QLabel(label)
        lb.setWordWrap(True)
        w.setMinimumWidth(105)
        h.addWidget(lb, 4)
        h.addWidget(w, 6)
        return box

    def _set(self, name, value):
        setattr(self.obj, name, value)
        self.changed.emit(name)

    def refresh(self) -> None:
        """relê os valores do objeto (depois de um arraste no 3D, por exemplo)"""
        for name, w in self.widgets.items():
            v = getattr(self.obj, name)
            if isinstance(w, (ParamSlider, NumberField)) and isinstance(v, (int, float)):
                w.setValue(float(v))
