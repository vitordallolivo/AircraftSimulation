"""Vista 3D de uma análise de carga aerodinâmica sobre o modelo do avião da GUI (o mesmo desenho da Montagem): as
superfícies pintadas por um campo (carga alar local, α efetivo, velocidade local, imersão na esteira...), setas com
ponta (força total, sustentação, força normal à superfície ou velocidade induzida), o vento relativo, os tubos das
hélices e o resto do avião em transparência.

Só lê a entrada padrão (`aerosim.interfaces.loads.LoadResult`): qualquer método que a produza (núcleo por faixas hoje;
VLM, painéis, CFD depois) aparece aqui sem mudar nada. Nenhuma conta aerodinâmica é feita aqui: as cores do modelo
saem do valor da face do método mais próxima de cada vértice.

    view = LoadView()
    view.set_result(result, aircraft)       # aircraft: o avião (desenho da GUI); sem ele, a malha do método
    view.set_field("alpha_ef"); view.set_vectors("sustentação (⟂ ao vento local)"); view.set_scale("por superfície")
    view.save_png("vista.png")
"""
from __future__ import annotations

import numpy as np
import pyqtgraph as pg
import pyqtgraph.opengl as gl
from pyqtgraph.opengl import shaders
from PyQt6 import QtCore, QtGui, QtWidgets

from aerosim.aero.load_geometry import arrow_meshes  # noqa: F401 (as setas: geometria sem Qt, compartilhada)
from aerosim.interfaces.loads import CAMPOS, LoadResult, label

from .view3d import COLORS, to_gl

SURFACE_KINDS = {"wing", "htail", "vtail", "control", "device"}
SCALES = ("mín–máx", "simétrica em 0", "por superfície")

# cor do campo com um sombreamento leve (a forma do perfil aparece e a cor continua perto da legenda)
shaders.ShaderProgram("aero_field", [
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
            gl_FragColor = vec4(v_color.rgb * (0.82 + 0.22 * p), v_color.a);
        }
    """),
])


def colormap(signed: bool):
    return pg.colormap.get("CET-D1" if signed else "turbo")


def normalize(values, scale: str, groups=None) -> tuple[np.ndarray, float, float, bool]:
    """(t em 0..1 por valor, mínimo, máximo, mapa divergente?) na escala pedida"""
    v = np.asarray(values, float)
    ok = np.isfinite(v)
    if not ok.any():
        return np.zeros(len(v)), 0.0, 1.0, False
    if scale == "por superfície" and groups is not None:
        t = np.zeros(len(v))
        for g in np.unique(groups):
            k = (groups == g) & ok
            if k.any():
                lo, hi = float(np.min(v[k])), float(np.max(v[k]))
                t[k] = (v[k] - lo) / (hi - lo) if hi - lo > 1e-12 else 0.5
        return t, 0.0, 1.0, False
    if scale == "simétrica em 0":
        m = float(np.max(np.abs(v[ok]))) or 1.0
        lo, hi, signed = -m, m, True
    else:
        lo, hi, signed = float(np.min(v[ok])), float(np.max(v[ok])), False
        if hi - lo < 1e-12:
            hi = lo + 1.0
    return np.clip((np.where(ok, v, lo) - lo) / (hi - lo), 0, 1), lo, hi, signed


def face_colors(values, signed: bool) -> tuple[np.ndarray, float, float]:
    """(cores RGBA por valor, mínimo, máximo): escala simétrica (com sinal) ou mín–máx"""
    t, lo, hi, sg = normalize(values, "simétrica em 0" if signed else "mín–máx")
    return np.asarray(colormap(sg).map(t, mode="float"), float), lo, hi


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
            g.setColorAt(float(t), cm.map(float(t), mode="qcolor"))
        p.fillRect(bar, g)
        p.setPen(QtGui.QColor(30, 30, 30))
        p.drawRect(bar)
        p.drawText(QtCore.QRect(rect.left() + 10, rect.top() + 2, rect.width() - 20, 18),
                   QtCore.Qt.AlignmentFlag.AlignLeft, self.title)
        y = bar.bottom() + 2
        fmt = lambda x: f"{x:.3g}"
        p.drawText(QtCore.QRect(bar.left(), y, 160, 16), QtCore.Qt.AlignmentFlag.AlignLeft, fmt(self.lo))
        p.drawText(QtCore.QRect(bar.center().x() - 80, y, 160, 16), QtCore.Qt.AlignmentFlag.AlignHCenter,
                   fmt(0.5 * (self.lo + self.hi)))
        p.drawText(QtCore.QRect(bar.right() - 160, y, 160, 16), QtCore.Qt.AlignmentFlag.AlignRight, fmt(self.hi))
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
        self.vectors = "força total"
        self.scale = "mín–máx"
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        row = QtWidgets.QHBoxLayout()
        self.combo = QtWidgets.QComboBox()
        self.combo.currentIndexChanged.connect(lambda _: self.set_field(self.combo.currentData()))
        self.vec_combo = QtWidgets.QComboBox()
        self.vec_combo.currentIndexChanged.connect(lambda _: self.set_vectors(self.vec_combo.currentData()))
        self.scale_combo = QtWidgets.QComboBox()
        self.scale_combo.addItems(SCALES)
        self.scale_combo.currentTextChanged.connect(self.set_scale)
        for lab, w in (("mapa:", self.combo), ("setas:", self.vec_combo), ("escala:", self.scale_combo)):
            row.addWidget(QtWidgets.QLabel(lab))
            row.addWidget(w, 1)
        v.addLayout(row)
        row2 = QtWidgets.QHBoxLayout()
        self.show_model = QtWidgets.QCheckBox("modelo da GUI (senão, a malha do método)")
        self.show_tubes = QtWidgets.QCheckBox("tubos das hélices")
        self.show_plane = QtWidgets.QCheckBox("resto do avião")
        self.show_wind = QtWidgets.QCheckBox("vento relativo")
        self.show_axes = QtWidgets.QCheckBox("eixos")
        for c in (self.show_model, self.show_tubes, self.show_plane, self.show_wind, self.show_axes):
            c.setChecked(True)
            c.toggled.connect(lambda _=False: self.redraw())
            row2.addWidget(c)
        row2.addStretch(1)
        v.addLayout(row2)
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
        self._frames = None

    # ------------------------------------------------------------------ dados
    def set_result(self, res: LoadResult, aircraft=None) -> None:
        self.result, self.aircraft = res, aircraft
        f = res.field
        names = [k for k in CAMPOS if f is not None and k in f.fields]
        names += [k for k in (f.fields if f is not None else {}) if k not in names]
        self.combo.blockSignals(True)
        self.combo.clear()
        for k in names:
            self.combo.addItem(label(k), k)
        if self.field not in names and names:
            self.field = names[0]
        if names:
            self.combo.setCurrentIndex(names.index(self.field))
        self.combo.blockSignals(False)
        vecs = [x.name for x in (f.vectors if f is not None else [])] + ["nenhuma"]
        self.vec_combo.blockSignals(True)
        self.vec_combo.clear()
        for k in vecs:
            self.vec_combo.addItem(k, k)
        if self.vectors not in vecs:
            self.vectors = vecs[0]
        self.vec_combo.setCurrentIndex(vecs.index(self.vectors))
        self.vec_combo.blockSignals(False)
        self.scale_combo.blockSignals(True)
        self.scale_combo.setCurrentText(self.scale)
        self.scale_combo.blockSignals(False)
        self._frames = self._face_frames(f) if f is not None else None
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

    def set_vectors(self, name: str | None) -> None:
        if name:
            self.vectors = name
            i = self.vec_combo.findData(name)
            if i >= 0 and self.vec_combo.currentIndex() != i:
                self.vec_combo.blockSignals(True)
                self.vec_combo.setCurrentIndex(i)
                self.vec_combo.blockSignals(False)
            self.redraw()

    def set_scale(self, name: str) -> None:
        self.scale = name
        i = self.scale_combo.findText(name)
        if i >= 0 and self.scale_combo.currentIndex() != i:
            self.scale_combo.blockSignals(True)
            self.scale_combo.setCurrentIndex(i)
            self.scale_combo.blockSignals(False)
        self.redraw()

    @staticmethod
    def _face_frames(f):
        """por face: centro, direção da envergadura, meia largura, direção da corda, meia corda, normal (quadriláteros);
        triângulos: só o centro (cores pelo centro mais próximo)"""
        V = np.asarray(f.vertices, float)
        F = np.asarray(f.faces, int)
        c = V[F].mean(axis=1)
        if F.shape[1] != 4:
            return dict(c=c)
        span = V[F[:, 1]] - V[F[:, 0]]
        hw = 0.5 * np.linalg.norm(span, axis=1)
        u = span / np.maximum(2 * hw, 1e-12)[:, None]
        ch = V[F[:, 0]] - V[F[:, 3]]
        hc = 0.5 * np.linalg.norm(ch, axis=1)
        w = ch / np.maximum(2 * hc, 1e-12)[:, None]
        return dict(c=c, u=u, hw=hw, w=w, hc=hc, n=np.cross(w, u))

    def nearest_face(self, P: np.ndarray) -> np.ndarray:
        """a face do método mais perto de cada ponto, medindo fora do retângulo dela (envergadura e corda) e na
        normal — um vértice do perfil grosso cai na faixa certa"""
        fr = self._frames
        d = np.asarray(P, float)[:, None, :] - fr["c"][None, :, :]
        if "u" not in fr:
            return np.argmin(np.sum(d * d, axis=2), axis=1)
        du = np.maximum(np.abs(np.einsum("pfk,fk->pf", d, fr["u"])) - fr["hw"], 0)
        dw = np.maximum(np.abs(np.einsum("pfk,fk->pf", d, fr["w"])) - fr["hc"], 0)
        dn = np.einsum("pfk,fk->pf", d, fr["n"])
        return np.argmin(du * du + dw * dw + 0.25 * dn * dn, axis=1)

    # ------------------------------------------------------------------ desenho
    def _clear(self) -> None:
        for it in self._items:
            self.gl.removeItem(it)
        self._items = []

    def _add(self, it) -> None:
        self.gl.addItem(it)
        self._items.append(it)

    def _arrows(self, origins, vecs, head, color, width=2.5) -> None:
        seg, (cv, cf) = arrow_meshes(np.asarray(origins, float), np.asarray(vecs, float), head)
        self._add(gl.GLLinePlotItem(pos=to_gl(seg), mode="lines", color=color, width=width, antialias=True,
                                    glOptions="translucent"))
        if len(cf):
            self._add(gl.GLMeshItem(vertexes=to_gl(cv), faces=cf, color=color, smooth=False, glOptions="opaque",
                                    computeNormals=False))

    def redraw(self) -> None:
        self._clear()
        res = self.result
        if res is None or res.field is None:
            return
        f = res.field
        size = float(np.ptp(f.vertices, axis=0).max()) if len(f.vertices) else 1.0
        vals = np.asarray(f.fields.get(self.field, np.full(len(f.faces), np.nan)), float)
        groups = f.face_surface
        t, lo, hi, signed = normalize(vals, self.scale, groups)
        colors = np.asarray(colormap(signed).map(t, mode="float"), float)
        meshes = {}
        if self.aircraft is not None:
            from aerosim.model.geometry import aircraft_meshes
            meshes = aircraft_meshes(self.aircraft)
        if self.show_plane.isChecked():                       # o resto do avião em transparência
            for parts in meshes.values():
                for (V, F), kind in parts:
                    if kind in SURFACE_KINDS:
                        continue
                    c = COLORS.get(kind, (0.7, 0.7, 0.7, 1))
                    self._add(gl.GLMeshItem(vertexes=to_gl(V), faces=F, color=(c[0], c[1], c[2], 0.22), smooth=False,
                                            shader="aero_twosided", glOptions="translucent", computeNormals=True))
        if self.show_model.isChecked() and meshes:
            # as superfícies do desenho da GUI, cada vértice com a cor da face do método mais próxima
            for parts in meshes.values():
                for (V, F), kind in parts:
                    if kind not in SURFACE_KINDS:
                        continue
                    k = self.nearest_face(V)
                    self._add(gl.GLMeshItem(vertexes=to_gl(V), faces=F, vertexColors=colors[k], smooth=True,
                                            shader="aero_field", glOptions="opaque", computeNormals=True))
        else:
            tri, src = f.triangles()
            self._add(gl.GLMeshItem(vertexes=to_gl(f.vertices), faces=tri, faceColors=colors[src], smooth=False,
                                    glOptions="opaque", computeNormals=False))
            edges = []
            for q in np.asarray(f.faces, int):
                for a, b in zip(q, np.roll(q, -1)):
                    edges += [f.vertices[a], f.vertices[b]]
            if edges:
                self._add(gl.GLLinePlotItem(pos=to_gl(np.array(edges)), mode="lines", color=(0.2, 0.2, 0.2, 0.35),
                                            width=1))
        note = []
        layer = next((x for x in f.vectors if x.name == self.vectors), None)
        if layer is not None and len(layer.vectors):
            mag = np.linalg.norm(layer.vectors, axis=1)
            if mag.max() > 1e-12:
                k = 0.18 * size / mag.max()                     # a maior seta = 18 % do avião
                self._arrows(layer.origins, k * np.asarray(layer.vectors, float), 0.022 * size, layer.color)
                note.append(f"{layer.name}: maior seta = {mag.max():.3g} {layer.unit}")
        if self.show_tubes.isChecked():
            for tb in f.tubes:
                self._tube(np.asarray(tb["centers"], float), np.asarray(tb["radius"], float))
        lo_all, hi_all = f.vertices.min(axis=0), f.vertices.max(axis=0)
        if self.show_wind.isChecked() and res.meta.get("vento") is not None:
            wd = np.asarray(res.meta["vento"], float)
            L = 0.3 * size
            tip = np.array([hi_all[0] + 0.12 * size, 0.0, lo_all[2] - 0.12 * size])
            col = (0.30, 0.30, 0.34, 1.0)
            self._arrows((tip - L * wd)[None, :], (L * wd)[None, :], 0.05 * size, col, 4)
            self._text(tip - L * wd + np.array([0, 0, -0.04 * size]),
                       f"vento relativo ({res.meta.get('V', 0):g} m/s, α = {res.meta.get('alpha', 0):.1f}°)", col)
        if self.show_axes.isChecked():
            o = np.array([lo_all[0] - 0.12 * size, lo_all[1] - 0.12 * size, hi_all[2] + 0.04 * size])
            L = 0.14 * size
            for d, name, c in (([1, 0, 0], "frente (+x)", (0.80, 0.10, 0.10, 1)),
                               ([0, 1, 0], "direita (+y)", (0.10, 0.55, 0.10, 1)),
                               ([0, 0, -1], "cima", (0.10, 0.25, 0.85, 1))):
                self._arrows(o[None, :], (L * np.array(d, float))[None, :], 0.03 * size, c, 3)
                self._text(o + 1.2 * L * np.array(d, float), name, c)
        title = label(self.field) + (" — por superfície (0 = mín., 1 = máx. de cada uma)"
                                     if self.scale == "por superfície" else "")
        if self.scale == "por superfície" and groups is not None:
            note.insert(0, "; ".join(f"{g}: {np.nanmin(vals[groups == g]):.3g} a {np.nanmax(vals[groups == g]):.3g}"
                                     for g in dict.fromkeys(groups)))
        self.legend.set(title, lo, hi, signed, "   ".join(note))

    def _text(self, p, text, color) -> None:
        c = QtGui.QColor.fromRgbF(*color[:3])
        self._add(gl.GLTextItem(pos=to_gl(np.asarray(p, float)), text=text, color=c, font=QtGui.QFont("Sans", 10)))

    def _tube(self, C: np.ndarray, R: np.ndarray) -> None:
        if len(C) < 2:
            return
        ax = C[-1] - C[0]
        ax /= np.linalg.norm(ax) or 1.0
        u = np.cross(ax, [0.0, 0.0, 1.0])
        if np.linalg.norm(u) < 1e-6:
            u = np.cross(ax, [0.0, 1.0, 0.0])
        u /= np.linalg.norm(u)
        w = np.cross(ax, u)
        n = 24
        ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
        ring = np.outer(np.cos(ang), u) + np.outer(np.sin(ang), w)
        V = np.vstack([C[i] + R[i] * ring for i in range(len(C))])
        F = []
        for i in range(len(C) - 1):
            for j in range(n):
                a, b = i * n + j, i * n + (j + 1) % n
                F += [[a, b, b + n], [a, b + n, a + n]]
        self._add(gl.GLMeshItem(vertexes=to_gl(V), faces=np.array(F), color=(0.95, 0.55, 0.15, 0.10), smooth=True,
                                glOptions="translucent", computeNormals=True))
        for i in range(0, len(C), max(1, len(C) // 6)):
            self._add(gl.GLLinePlotItem(pos=to_gl(np.vstack([C[i] + R[i] * ring, C[i] + R[i] * ring[:1]])),
                                        color=(0.85, 0.35, 0.05, 0.7), width=1.5))

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
