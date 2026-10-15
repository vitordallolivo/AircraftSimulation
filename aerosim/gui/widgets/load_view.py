"""Vista 3D de uma análise de carga aerodinâmica: a malha das superfícies pintada por um campo (carga alar local,
α efetivo, velocidade local...), setas de força e de velocidade induzida, tubos da esteira e o avião em transparência.

Só lê a entrada padrão (`aerosim.interfaces.loads.LoadResult`): qualquer método que a produza (núcleo por faixas hoje;
VLM, painéis, CFD depois) aparece aqui sem mudar nada. Nenhuma conta aerodinâmica é feita aqui.

    view = LoadView()
    view.set_result(result, aircraft)       # aircraft: opcional (desenha fuselagem, tubos, motores em transparência)
    view.set_field("alpha_ef")
    view.save_png("vista.png")
"""
from __future__ import annotations

import numpy as np
import pyqtgraph as pg
import pyqtgraph.opengl as gl
from PyQt6 import QtCore, QtGui, QtWidgets

from aerosim.interfaces.loads import CAMPOS, LoadResult, label

from .view3d import COLORS, to_gl

GHOST = {"fuselage", "boom", "motor", "propdisk", "wheel", "strut", "payload", "tank"}   # do avião, só o que não é malha de carga


def colormap(signed: bool):
    return pg.colormap.get("CET-D1" if signed else "viridis")


def face_colors(values: np.ndarray, signed: bool) -> tuple[np.ndarray, float, float]:
    """(cores RGBA 0..1 por face, mínimo, máximo da escala); com sinal: escala simétrica em torno de zero"""
    v = np.asarray(values, float)
    ok = np.isfinite(v)
    if not ok.any():
        return np.tile([0.7, 0.7, 0.7, 1.0], (len(v), 1)), 0.0, 1.0
    if signed:
        m = float(np.max(np.abs(v[ok]))) or 1.0
        lo, hi = -m, m
    else:
        lo, hi = float(np.min(v[ok])), float(np.max(v[ok]))
        if hi - lo < 1e-12:
            hi = lo + 1.0
    t = np.clip((np.where(ok, v, lo) - lo) / (hi - lo), 0, 1)
    rgba = colormap(signed).map(t, mode="float")
    return np.asarray(rgba, float), lo, hi


class Legend(QtWidgets.QWidget):
    """barra de cores com o nome do campo e a escala"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(54)
        self.title, self.lo, self.hi, self.signed, self.note = "", 0.0, 1.0, True, ""

    def set(self, title, lo, hi, signed, note=""):
        self.title, self.lo, self.hi, self.signed, self.note = title, lo, hi, signed, note
        self.update()

    def paint_on(self, p: QtGui.QPainter, rect: QtCore.QRect) -> None:
        cm = colormap(self.signed)
        bar = QtCore.QRect(rect.left() + 10, rect.top() + 22, rect.width() - 20, 12)
        g = QtGui.QLinearGradient(QtCore.QPointF(bar.left(), 0), QtCore.QPointF(bar.right(), 0))
        for t in np.linspace(0, 1, 11):
            c = cm.map(float(t), mode="qcolor")
            g.setColorAt(float(t), c)
        p.fillRect(bar, g)
        p.setPen(QtGui.QColor(30, 30, 30))
        p.drawRect(bar)
        p.drawText(QtCore.QRect(rect.left() + 10, rect.top() + 2, rect.width() - 20, 18),
                   QtCore.Qt.AlignmentFlag.AlignLeft, self.title)
        y = bar.bottom() + 2
        fmt = lambda x: f"{x:.3g}"
        p.drawText(QtCore.QRect(bar.left(), y, 120, 16), QtCore.Qt.AlignmentFlag.AlignLeft, fmt(self.lo))
        p.drawText(QtCore.QRect(bar.center().x() - 60, y, 120, 16), QtCore.Qt.AlignmentFlag.AlignHCenter,
                   fmt(0.5 * (self.lo + self.hi)))
        p.drawText(QtCore.QRect(bar.right() - 120, y, 120, 16), QtCore.Qt.AlignmentFlag.AlignRight, fmt(self.hi))
        if self.note:
            p.drawText(QtCore.QRect(rect.left() + 10, rect.top() + 2, rect.width() - 20, 18),
                       QtCore.Qt.AlignmentFlag.AlignRight, self.note)

    def paintEvent(self, _):
        p = QtGui.QPainter(self)
        self.paint_on(p, self.rect())
        p.end()


class LoadView(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.result: LoadResult | None = None
        self.aircraft = None
        self.field = "carga"
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        row = QtWidgets.QHBoxLayout()
        self.combo = QtWidgets.QComboBox()
        self.combo.currentIndexChanged.connect(lambda _: self.set_field(self.combo.currentData()))
        row.addWidget(QtWidgets.QLabel("mapa:"))
        row.addWidget(self.combo, 1)
        self.show_force = QtWidgets.QCheckBox("forças")
        self.show_ind = QtWidgets.QCheckBox("velocidade induzida")
        self.show_tubes = QtWidgets.QCheckBox("esteira")
        self.show_plane = QtWidgets.QCheckBox("avião")
        for c, on in ((self.show_force, True), (self.show_ind, False), (self.show_tubes, True), (self.show_plane, True)):
            c.setChecked(on)
            c.toggled.connect(lambda _=False: self.redraw())
            row.addWidget(c)
        v.addLayout(row)
        self.gl = gl.GLViewWidget()
        self.gl.setBackgroundColor((245, 246, 250))
        self.gl.setCameraPosition(distance=3.6, elevation=28, azimuth=-125)
        self.gl.setMinimumSize(420, 320)
        v.addWidget(self.gl, 1)
        self.legend = Legend()
        v.addWidget(self.legend)
        self.info = QtWidgets.QLabel()
        self.info.setWordWrap(True)
        self.info.setStyleSheet("color: #444")
        v.addWidget(self.info)
        self._items: list = []

    # ------------------------------------------------------------------ dados
    def set_result(self, res: LoadResult, aircraft=None) -> None:
        self.result, self.aircraft = res, aircraft
        names = [k for k in CAMPOS if res.field is not None and k in res.field.fields]
        names += [k for k in (res.field.fields if res.field is not None else {}) if k not in names]
        self.combo.blockSignals(True)
        self.combo.clear()
        for k in names:
            self.combo.addItem(label(k), k)
        if self.field in names:
            self.combo.setCurrentIndex(names.index(self.field))
        elif names:
            self.field = names[0]
        self.combo.blockSignals(False)
        m = res.meta
        txt = [m.get("caso", "")]
        if m.get("modificadores"):
            txt.append("modificadores: " + "; ".join(m["modificadores"]))
        txt.append(f"fonte: {m.get('fonte', '?')}")
        txt += ["⚠ " + a for a in m.get("avisos", [])]
        self.info.setText("<br>".join(t for t in txt if t))
        self.redraw()

    def set_field(self, name: str | None) -> None:
        if name:
            self.field = name
            self.redraw()

    # ------------------------------------------------------------------ desenho
    def _clear(self) -> None:
        for it in self._items:
            self.gl.removeItem(it)
        self._items = []

    def _add(self, it) -> None:
        self.gl.addItem(it)
        self._items.append(it)

    def redraw(self) -> None:
        self._clear()
        res = self.result
        if res is None or res.field is None:
            return
        f = res.field
        size = float(np.ptp(f.vertices, axis=0).max()) if len(f.vertices) else 1.0
        if self.show_plane.isChecked() and self.aircraft is not None:
            from aerosim.model.geometry import aircraft_meshes
            for _key, parts in aircraft_meshes(self.aircraft).items():
                for (V, F), kind in parts:
                    if kind not in GHOST:
                        continue
                    c = COLORS.get(kind, (0.7, 0.7, 0.7, 1))
                    self._add(gl.GLMeshItem(vertexes=to_gl(V), faces=F, color=(c[0], c[1], c[2], 0.25), smooth=False,
                                            shader="aero_twosided", glOptions="translucent", computeNormals=True))
        signed = CAMPOS.get(self.field, ("", "", True))[2]
        vals = f.fields.get(self.field, np.full(len(f.faces), np.nan))
        cols, lo, hi = face_colors(vals, signed)
        tri, src = f.triangles()
        # sem sombreamento: a cor da face é exatamente a da legenda
        self._add(gl.GLMeshItem(vertexes=to_gl(f.vertices), faces=tri, faceColors=cols[src], smooth=False,
                                glOptions="opaque", computeNormals=False))
        edges = []
        for q in np.asarray(f.faces, int):
            for a, b in zip(q, np.roll(q, -1)):
                edges += [f.vertices[a], f.vertices[b]]
        if edges:
            self._add(gl.GLLinePlotItem(pos=to_gl(np.array(edges)), mode="lines", color=(0.2, 0.2, 0.2, 0.35), width=1))
        note = []
        for layer, box in zip(f.vectors, (self.show_force, self.show_ind)):
            if not box.isChecked() or not len(layer.vectors):
                continue
            mag = np.linalg.norm(layer.vectors, axis=1)
            if mag.max() <= 1e-12:
                continue
            k = 0.18 * size / mag.max()                       # a maior seta = 18 % do avião
            seg = np.empty((2 * len(mag), 3))
            seg[0::2] = layer.origins
            seg[1::2] = layer.origins + k * layer.vectors
            self._add(gl.GLLinePlotItem(pos=to_gl(seg), mode="lines", color=layer.color, width=2.5, antialias=True,
                                        glOptions="translucent"))
            note.append(f"{layer.name}: maior seta = {mag.max():.3g} {layer.unit}")
        if self.show_tubes.isChecked():
            for t in f.tubes:
                C, R = np.asarray(t["centers"], float), np.asarray(t["radius"], float)
                if len(C) < 2:
                    continue
                ax = C[-1] - C[0]
                ax /= np.linalg.norm(ax) or 1.0
                u = np.cross(ax, [0.0, 0.0, 1.0])
                if np.linalg.norm(u) < 1e-6:
                    u = np.cross(ax, [0.0, 1.0, 0.0])
                u /= np.linalg.norm(u)
                w = np.cross(ax, u)
                ang = np.linspace(0, 2 * np.pi, 33)
                for i in range(0, len(C), max(1, len(C) // 8)):
                    ring = C[i] + R[i] * (np.outer(np.cos(ang), u) + np.outer(np.sin(ang), w))
                    self._add(gl.GLLinePlotItem(pos=to_gl(ring), color=(0.85, 0.35, 0.05, 0.6), width=1.5))
                for a in (0, np.pi / 2, np.pi, 3 * np.pi / 2):
                    line = C + R[:, None] * (np.cos(a) * u + np.sin(a) * w)
                    self._add(gl.GLLinePlotItem(pos=to_gl(line), color=(0.85, 0.35, 0.05, 0.4), width=1))
        self.legend.set(label(self.field), lo, hi, signed, "   ".join(note))

    # ------------------------------------------------------------------ imagem
    def set_camera(self, distance=None, elevation=None, azimuth=None) -> None:
        self.gl.setCameraPosition(distance=distance, elevation=elevation, azimuth=azimuth)

    def save_png(self, path: str) -> None:
        """a vista 3D (do tamanho da janela) com a legenda e o texto embaixo, numa imagem"""
        QtWidgets.QApplication.processEvents()
        q = self.gl.grabFramebuffer()
        w, h = q.width(), q.height()
        out = QtGui.QImage(w, h + 110, QtGui.QImage.Format.Format_RGB32)
        out.fill(QtGui.QColor(255, 255, 255))
        p = QtGui.QPainter(out)
        p.drawImage(0, 0, q)
        self.legend.paint_on(p, QtCore.QRect(0, h, w, 56))
        doc = QtGui.QTextDocument()
        doc.setHtml(f"<div style='color:#333;font-size:12px'>{self.info.text()}</div>")
        doc.setTextWidth(w - 20)
        p.translate(10, h + 56)
        doc.drawContents(p)
        p.end()
        out.save(path)
