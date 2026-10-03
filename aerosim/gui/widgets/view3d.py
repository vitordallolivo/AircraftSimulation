"""Visualização 3D da aeronave (pyqtgraph.opengl) com seleção e arraste de componentes.

Eixos: o modelo usa o corpo (x frente, y direita, z baixo); a tela usa z para cima,
então (X, Y, Z)_GL = (x, −y, −z). No modo "mover", clicar perto de um componente o
seleciona e arrastar o move no plano da tela (ou só num eixo, se travado).
"""
from __future__ import annotations

import math

import numpy as np
import pyqtgraph.opengl as gl
from pyqtgraph.opengl import shaders
from PyQt6 import QtCore, QtGui

from aerosim.model.geometry import aircraft_meshes, component_position, move_component

COLORS = {
    "wing": (0.30, 0.55, 0.85, 1.0), "htail": (0.35, 0.70, 0.45, 1.0), "vtail": (0.55, 0.45, 0.80, 1.0),
    "control": (0.95, 0.65, 0.15, 1.0), "device": (0.20, 0.62, 0.62, 1.0), "fuselage": (0.75, 0.75, 0.78, 1.0), "boom": (0.4, 0.4, 0.42, 1.0),
    "motor": (0.85, 0.25, 0.25, 1.0), "propdisk": (0.9, 0.3, 0.3, 0.25), "tank": (0.6, 0.85, 0.95, 0.25),
    "liquid": (0.15, 0.45, 0.95, 0.75), "payload": (0.55, 0.35, 0.15, 1.0), "ballast": (0.25, 0.25, 0.28, 1.0), "wheel": (0.1, 0.1, 0.1, 1.0),
    "strut": (0.3, 0.3, 0.3, 1.0),
}
SELECTED = (1.0, 0.95, 0.2, 1.0)

# sombreamento dos dois lados (as superfícies finas são vistas por cima e por baixo)
shaders.ShaderProgram("aero_twosided", [
    shaders.VertexShader("""
        uniform mat4 u_mvp;
        uniform mat3 u_normal;
        attribute vec4 a_position;
        attribute vec3 a_normal;
        attribute vec4 a_color;
        varying vec4 v_color;
        varying vec3 v_normal;
        void main() {
            v_normal = normalize(u_normal * a_normal);
            v_color = a_color;
            gl_Position = u_mvp * a_position;
        }
    """),
    shaders.FragmentShader("""
        #ifdef GL_ES
        precision mediump float;
        #endif
        varying vec4 v_color;
        varying vec3 v_normal;
        void main() {
            float p = abs(dot(v_normal, normalize(vec3(0.4, -0.5, 0.75))));
            gl_FragColor = vec4(v_color.rgb * (0.45 + 0.6 * p), v_color.a);
        }
    """),
])
B2GL = np.array([1.0, -1.0, -1.0])


def to_gl(p) -> np.ndarray:
    return np.asarray(p, float) * B2GL


class AircraftView(gl.GLViewWidget):
    componentSelected = QtCore.pyqtSignal(str)
    componentMoved = QtCore.pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setBackgroundColor((245, 246, 250))
        self.setCameraPosition(distance=4.0, elevation=22, azimuth=-130)
        self.aircraft = None
        self.selected: str | None = None
        self.move_mode = True
        self.axis_lock = "plano"          # plano | x | y | z
        self._items: list = []
        self._drag: str | None = None
        self._last = None
        self._markers: dict = {}
        grid = gl.GLGridItem()
        grid.setSize(6, 6)
        grid.setSpacing(0.25, 0.25)
        grid.translate(0, 0, -0.3)
        grid.setColor((0, 0, 0, 40))
        self.addItem(grid)
        self.addItem(gl.GLAxisItem(size=QtGui.QVector3D(0.4, 0.4, 0.4)))

    # ------------------------------------------------------------------ desenho
    def set_aircraft(self, ac) -> None:
        self.aircraft = ac
        self.rebuild()

    def rebuild(self) -> None:
        for it in self._items:
            self.removeItem(it)
        self._items = []
        if self.aircraft is None:
            return
        for key, parts in aircraft_meshes(self.aircraft).items():
            for (V, F), kind in parts:
                col = SELECTED if key == self.selected and kind not in ("propdisk", "tank", "liquid") else COLORS.get(kind, (0.7, 0.7, 0.7, 1))
                item = gl.GLMeshItem(vertexes=to_gl(V), faces=F, color=col, smooth=False, shader="aero_twosided",
                                     glOptions="translucent" if col[3] < 1 else "opaque", computeNormals=True)
                self.addItem(item)
                self._items.append(item)
        self._draw_markers()

    def set_markers(self, cg=None, np_x=None, wind=None) -> None:
        """CG (ponto), ponto neutro (x), vento (velocidade, de onde vem em graus)"""
        if cg is not None:
            self._markers["cg"] = np.asarray(cg, float)
        if np_x is not None:
            self._markers["np"] = float(np_x)
        if wind is not None:
            self._markers["wind"] = wind
        self._draw_markers()

    def _draw_markers(self) -> None:
        for it in getattr(self, "_marker_items", []):
            self.removeItem(it)
        self._marker_items = []
        if "cg" in self._markers:
            p = to_gl(self._markers["cg"])
            sp = gl.GLScatterPlotItem(pos=np.array([p]), color=(0.9, 0.1, 0.1, 1), size=14, pxMode=True)
            self._marker_items.append(sp)
            ln = gl.GLLinePlotItem(pos=np.array([p + [0, 0, 0.25], p - [0, 0, 0.25]]), color=(0.9, 0.1, 0.1, 1), width=2)
            self._marker_items.append(ln)
        if "np" in self._markers:
            x = self._markers["np"]
            self._marker_items.append(gl.GLLinePlotItem(pos=np.array([[x, 0, 0.3], [x, 0, -0.3]]),
                                                        color=(0.1, 0.6, 0.1, 1), width=3))
        if "wind" in self._markers:
            V, frm = self._markers["wind"]
            if V > 0.05:
                a = math.radians(frm)
                d = -np.array([math.cos(a), math.sin(a), 0.0])           # para onde sopra (N, E)
                tip = np.array([0.0, 0.0, 0.6])
                L = 0.25 + 0.08 * V
                tail = tip - to_gl(d) * L
                head = [tip, tip - to_gl(d) * 0.12 + to_gl([-d[1], d[0], 0]) * 0.06,
                        tip, tip - to_gl(d) * 0.12 - to_gl([-d[1], d[0], 0]) * 0.06]
                self._marker_items.append(gl.GLLinePlotItem(pos=np.array([tail, tip]), color=(0.1, 0.4, 0.9, 1), width=4))
                self._marker_items.append(gl.GLLinePlotItem(pos=np.array(head), color=(0.1, 0.4, 0.9, 1), width=4,
                                                            mode="lines"))
        for it in self._marker_items:
            it.setGLOptions("translucent")     # no fundo claro, "additive" (padrão) some
            self.addItem(it)

    # ------------------------------------------------------------------ seleção e arraste
    def select(self, key: str | None) -> None:
        if key != self.selected:
            self.selected = key
            self.rebuild()

    def _project(self, p_gl) -> tuple[float, float]:
        w, h = self.width(), self.height()
        M = self.projectionMatrix((0, 0, w, h), (0, 0, w, h)) * self.viewMatrix()
        v = M.map(QtGui.QVector4D(float(p_gl[0]), float(p_gl[1]), float(p_gl[2]), 1.0))
        if abs(v.w()) < 1e-12:
            return -1e9, -1e9
        return (v.x() / v.w() + 1) * 0.5 * w, (1 - v.y() / v.w()) * 0.5 * h

    def pick(self, sx: float, sy: float, radius: float = 28.0) -> str | None:
        if self.aircraft is None:
            return None
        best, bd = None, radius
        for key in aircraft_meshes(self.aircraft):
            p = component_position(self.aircraft, key)
            if p is None:
                continue
            px, py = self._project(to_gl(p))
            d = math.hypot(px - sx, py - sy)
            if d < bd:
                best, bd = key, d
        return best

    def _camera_axes(self):
        V = self.viewMatrix()
        right = np.array([V.row(0).x(), V.row(0).y(), V.row(0).z()])
        up = np.array([V.row(1).x(), V.row(1).y(), V.row(1).z()])
        return right, up

    def mousePressEvent(self, ev):
        pos = ev.position()
        if self.move_mode and ev.button() == QtCore.Qt.MouseButton.LeftButton:
            key = self.pick(pos.x(), pos.y())
            if key is not None:
                self._drag = key
                self._last = (pos.x(), pos.y())
                self.select(key)
                self.componentSelected.emit(key)
                ev.accept()
                return
        self._drag = None
        super().mousePressEvent(ev)

    def mouseMoveEvent(self, ev):
        if self._drag is not None and self.aircraft is not None:
            pos = ev.position()
            dx, dy = pos.x() - self._last[0], pos.y() - self._last[1]
            self._last = (pos.x(), pos.y())
            scale = 2 * self.opts["distance"] * math.tan(math.radians(self.opts["fov"]) / 2) / max(self.width(), 1)
            right, up = self._camera_axes()
            dgl = (dx * right - dy * up) * scale
            dbody = dgl * B2GL
            if self.axis_lock in ("x", "y", "z"):
                keep = "xyz".index(self.axis_lock)
                dbody = np.array([dbody[i] if i == keep else 0.0 for i in range(3)])
            p = component_position(self.aircraft, self._drag)
            move_component(self.aircraft, self._drag, p + dbody)
            self.rebuild()
            self.componentMoved.emit(self._drag)
            ev.accept()
            return
        super().mouseMoveEvent(ev)

    def mouseReleaseEvent(self, ev):
        self._drag = None
        super().mouseReleaseEvent(ev)
