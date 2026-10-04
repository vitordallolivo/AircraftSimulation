"""Gráficos da aba (pyqtgraph) montados a partir das PlotSpec da simulação.

Cada gráfico é um widget com altura própria (a aba rola), com a legenda embaixo, fora das curvas.
Tipos: 2d (curvas, dispersão, faixas, linhas e marcadores) e 3d (trajetória no espaço).
Durante a corrida desenha os canais do registro (`ys` de gráficos "log" e `live_ys` dos de séries);
no fim, desenha as séries do resultado com o estilo que a simulação pediu (`_color`, `_symbol`...).
"""
from __future__ import annotations

import math
import re
from html import escape

import numpy as np
import pyqtgraph as pg
from PyQt6 import QtCore, QtWidgets

from aerosim.interfaces.simulation import PlotSpec, SimResult

# canais em radianos no registro: mostrados em graus
ANGLES = {"phi", "theta", "psi", "p", "q", "r", "alpha", "beta", "gamma", "chi", "thc", "alc", "phic", "de", "da",
          "dr", "dw"}
PALETTE = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf", "#e377c2", "#7f7f7f"]
SYMBOLS = {"o": "o", "star": "star", "s": "s", "t": "t", "d": "d", "+": "+", "x": "x", "v": "t1", "^": "t"}
DASH = {1: QtCore.Qt.PenStyle.DashLine, "dash": QtCore.Qt.PenStyle.DashLine, "dot": QtCore.Qt.PenStyle.DotLine,
        "dashdot": QtCore.Qt.PenStyle.DashDotLine}

pg.setConfigOptions(antialias=True, background="w", foreground="k")


GREEK = {"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "eta": "η", "theta": "θ", "mu": "μ",
         "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Delta": "Δ",
         "pi": "π", "lambda": "λ"}
_SUB = re.compile(r"([A-Za-zα-ωΑ-Ω])_(\{[^}]*\}|[A-Za-z0-9α-ω]+)")
_SUP = re.compile(r"\^(\{[^}]*\}|[0-9A-Za-z+\-]+)")


def tex(s: str) -> str:
    """notação LaTeX simples -> HTML do Qt: $...$ em itálico, \\delta -> δ, x_{ab} e x^2 em sub/sobrescrito;
    fora de $...$ também converte índices como C_L, V_e, n_dec"""
    if not s:
        return s

    def conv(t: str) -> str:
        t = re.sub(r"\\([A-Za-z]+)", lambda m: GREEK.get(m.group(1), m.group(1)), t)
        t = _SUB.sub(lambda m: f"{m.group(1)}<sub>{m.group(2).strip('{}')}</sub>", t)
        t = _SUP.sub(lambda m: f"<sup>{m.group(1).strip('{}')}</sup>", t)
        return t
    parts = s.split("$")
    out = []
    for i, part in enumerate(parts):
        out.append(f"<i>{conv(part)}</i>" if i % 2 else conv(part))
    return "".join(out)


def is_angle(ch: str) -> bool:
    return ch in ANGLES or ch.startswith("slosh_")


def _pen(color, width=1.8, dash=None):
    return pg.mkPen(color, width=width, style=DASH.get(dash, QtCore.Qt.PenStyle.SolidLine) if dash else
                    QtCore.Qt.PenStyle.SolidLine)


def _tables(spec: PlotSpec, res: SimResult) -> tuple[list, bool, str]:
    name = spec.source.split(":", 1)[1]
    if name.endswith("*"):
        tabs = [(k, v) for k, v in res.series.items() if k.startswith(name[:-1])]
    else:
        tabs = [(name, res.series.get(name))]
    return tabs, len(tabs) > 1 or name.endswith("*"), name


class _Plot2D(QtWidgets.QWidget):
    def __init__(self, spec: PlotSpec, height: int, legend_cols: int = 3):
        super().__init__()
        self.spec = spec
        self.lay = pg.GraphicsLayoutWidget()
        # a largura vem do painel (legendas longas não alargam a aba e não escondem o fim do eixo)
        ign = QtWidgets.QSizePolicy.Policy.Ignored
        self.lay.setSizePolicy(ign, QtWidgets.QSizePolicy.Policy.Expanding)
        self.setSizePolicy(ign, QtWidgets.QSizePolicy.Policy.Preferred)
        self.setMinimumWidth(240)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self.lay)
        self.setMinimumHeight(spec.height or height)
        p = self.plot = self.lay.addPlot(row=0, col=0, title=f"<b>{tex(spec.title)}</b>")
        p.showGrid(x=True, y=True, alpha=0.3)
        p.setLabel("bottom", tex(spec.xlabel))
        p.setLabel("left", tex(spec.ylabel))
        for ax in ("bottom", "left"):
            p.getAxis(ax).enableAutoSIPrefix(False)
        if spec.aspect:
            p.setAspectLocked(True)
        if spec.invert_y:
            p.invertY(True)
        self.legend = pg.LegendItem(colCount=legend_cols, labelTextSize="8pt", horSpacing=14, verSpacing=-4)
        self.lay.addItem(self.legend, row=1, col=0)
        self.lay.ci.layout.setRowStretchFactor(0, 10)
        self.live: dict[str, pg.PlotDataItem] = {}
        ys = spec.ys if spec.source == "log" else spec.live_ys
        for j, y in enumerate(ys):
            c = p.plot([], [], pen=_pen(PALETTE[j % len(PALETTE)], 1.6), connect="finite")
            self.legend.addItem(c, tex(y))
            self.live[y] = c

    def clear_final(self):
        self.plot.clear()
        self.legend.clear()
        self.live = {}

    def draw_tables(self, res: SimResult):
        s, p, leg = self.spec, self.plot, self.legend
        tables, many, name = _tables(s, res)
        k = 0
        for tname, tab in tables:
            if not isinstance(tab, dict):
                continue
            rest = tname[len(name) - 1:] if name.endswith("*") else tname
            color = tab.get("_color") or PALETTE[k % len(PALETTE)]
            width = float(tab.get("_width", 1.8))
            dash = tab.get("_dash")
            label = tab.get("_label", rest)
            if "_ylim" in tab or "_xlim" in tab:      # escala do gráfico (as curvas continuam inteiras)
                if "_ylim" in tab:
                    p.vb.enableAutoRange(axis="y", enable=False)
                    p.setYRange(*tab["_ylim"], padding=0.02)
                if "_xlim" in tab:
                    p.vb.enableAutoRange(axis="x", enable=False)
                    p.setXRange(*tab["_xlim"], padding=0.02)
                continue
            # linhas e faixas de referência
            if "_vline" in tab or "_hline" in tab:
                vert = "_vline" in tab
                ln = pg.InfiniteLine(pos=float(tab["_vline" if vert else "_hline"]), angle=90 if vert else 0,
                                     pen=_pen(color, width if "_width" in tab else 1.2, dash or "dash"))
                p.addItem(ln)
                if not tab.get("_nolegend"):
                    leg.addItem(pg.PlotDataItem([], [], pen=_pen(color, 1.4, dash or "dash")), tex(label))
                k += 1
                continue
            if "_vspan" in tab:
                c = pg.mkColor(color)
                c.setAlpha(int(tab.get("_alpha", 28)))
                reg = pg.LinearRegionItem(values=list(tab["_vspan"]), movable=False, brush=pg.mkBrush(c),
                                          pen=pg.mkPen(None))
                reg.setZValue(-20)
                p.addItem(reg)
                if not tab.get("_nolegend"):
                    leg.addItem(pg.BarGraphItem(x=[0], height=[0], width=0, brush=pg.mkBrush(color)), tex(label))
                continue
            if s.x not in tab:
                continue
            for y in s.ys:
                if y not in tab:
                    continue
                xs = np.asarray(tab[s.x], float)
                ys = np.asarray(tab[y], float)
                lab = (f"{label}: {y}" if len(s.ys) > 1 else label) if many else tab.get("_label", y)
                if s.swap:
                    xs, ys = ys, xs
                col_ = tab.get("_color") or PALETTE[k % len(PALETTE)]
                k += 1
                fill = tab.get("_fill")
                sym = tab.get("_symbol") or ("o" if tab.get("_marker") else None)
                fillx = tab.get("_fillx")
                if (fill and fill in tab) or (fillx and fillx in tab):   # região sombreada entre duas curvas
                    if fill and fill in tab:
                        c2 = pg.PlotDataItem(xs, np.asarray(tab[fill], float), pen=pg.mkPen(None))
                    else:                         # mesma y, outro x (ex.: envelope V_min(h) a V_max(h))
                        c2 = pg.PlotDataItem(np.asarray(tab[fillx], float), ys, pen=pg.mkPen(None))
                    c1 = pg.PlotDataItem(xs, ys, pen=pg.mkPen(col_, width=1))
                    cc = pg.mkColor(col_)
                    cc.setAlpha(110 if tab.get("_strong") else 45)
                    for it in (c1, c2, pg.FillBetweenItem(c1, c2, brush=pg.mkBrush(cc))):
                        p.addItem(it)
                    if not tab.get("_nolegend"):
                        leg.addItem(c1, tex(lab))
                    continue
                if sym:
                    size = float(tab.get("_size", 18 if sym == "star" else 11))
                    it = p.plot(xs, ys, pen=_pen(col_, width, dash) if tab.get("_line") else None,
                                symbol=SYMBOLS.get(sym, sym), symbolSize=size, symbolBrush=col_,
                                symbolPen=pg.mkPen("k", width=0.8))
                    it.setZValue(10)
                elif s.scatter:
                    it = p.plot(xs, ys, pen=_pen(col_, 1, "dash"), symbol="o", symbolSize=7, symbolBrush=col_)
                else:
                    it = p.plot(xs, ys, pen=_pen(col_, width, dash), connect="finite")
                if not tab.get("_nolegend"):
                    leg.addItem(it, tex(lab))


class _Plot3D(QtWidgets.QWidget):
    """trajetória no espaço: (leste, norte, altura) com grade no chão e legenda em texto"""

    def __init__(self, spec: PlotSpec, height: int):
        super().__init__()
        import pyqtgraph.opengl as gl
        self.gl = gl
        self.spec = spec
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        t = QtWidgets.QLabel(f"<b>{tex(spec.title)}</b>")
        t.setToolTip("arraste para girar, roda do mouse para aproximar")
        t.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
        v.addWidget(t)
        self.view = gl.GLViewWidget()
        self.view.setBackgroundColor("w")
        self.view.setMinimumHeight((spec.height or height) - 60)
        v.addWidget(self.view, 1)
        self.leg = QtWidgets.QLabel()
        self.leg.setWordWrap(True)
        v.addWidget(self.leg)
        self.setMinimumHeight(spec.height or height)
        self.items = []
        self.live = None
        self._grid()

    def _grid(self, size=400.0, spacing=50.0):
        g = self.gl.GLGridItem()
        g.setSize(size, size)
        g.setSpacing(spacing, spacing)
        g.setColor((0, 0, 0, 60))
        self.view.addItem(g)
        self.items.append(g)

    def _add(self, pts, color, width=2.0):
        c = pg.mkColor(color)
        it = self.gl.GLLinePlotItem(pos=pts, color=(c.redF(), c.greenF(), c.blueF(), 1.0), width=width,
                                    antialias=True, mode="line_strip")
        self.view.addItem(it)
        self.items.append(it)
        return it

    def clear_final(self):
        for it in self.items:
            self.view.removeItem(it)
        self.items = []
        self.live = None

    def set_live(self, x, y, z):
        pts = np.column_stack([x, y, np.asarray(z) * getattr(self, "zscale", 10.0)])
        pts = pts[np.isfinite(pts).all(axis=1)]
        if not len(pts):
            return
        if self.live is None:
            self.live = self._add(pts, "#1f77b4", 2.0)
        else:
            self.live.setData(pos=pts)

    def draw_tables(self, res: SimResult):
        s = self.spec
        self.clear_final()
        tables, _, name = _tables(s, res)
        items, legend = [], []
        for tname, tab in tables:
            if not isinstance(tab, dict) or s.x not in tab or not s.ys or s.ys[0] not in tab or s.z not in tab:
                continue
            pts = np.column_stack([np.asarray(tab[s.x], float), np.asarray(tab[s.ys[0]], float),
                                   np.asarray(tab[s.z], float)])
            color = tab.get("_color", PALETTE[len(legend) % len(PALETTE)])
            items.append((pts, color, tab))
            if not tab.get("_nolegend"):
                rest = tname[len(name) - 1:] if name.endswith("*") else tname
                mark = "●" if tab.get("_symbol") else "━━"         # no 3D os eventos são pontos
                lab = str(tab.get("_label", rest)).lstrip("★ ")
                legend.append(f"<span style='color:{color}'>{mark}</span> {tex(escape(lab))}")
        if not items:
            return
        P = np.vstack([q[0][np.isfinite(q[0]).all(axis=1)] for q in items])
        lo, hi = P.min(axis=0), P.max(axis=0)
        span = float(max(hi[0] - lo[0], hi[1] - lo[1], 20.0))
        # altura exagerada: a trajetória de um circuito tem centenas de metros e poucos de altura
        k = max(1.0, round(0.25 * span / max(hi[2] - lo[2], 1.0)))
        self.zscale = k
        for pts, color, tab in items:
            q = pts * np.array([1.0, 1.0, k])
            if tab.get("_segments"):                 # silhuetas: centro esticado, desenho em escala real
                off = np.column_stack([np.asarray(tab["oe"], float), np.asarray(tab["on"], float),
                                       np.asarray(tab["oh"], float)])
                c = pg.mkColor(color)
                it = self.gl.GLLinePlotItem(pos=q + off, color=(c.redF(), c.greenF(), c.blueF(), 1.0),
                                            width=float(tab.get("_width", 1.5)), antialias=True, mode="lines")
                self.view.addItem(it)
                self.items.append(it)
                continue
            if tab.get("_symbol"):
                c = pg.mkColor(color)
                it = self.gl.GLScatterPlotItem(pos=q, color=(c.redF(), c.greenF(), c.blueF(), 1.0),
                                               size=float(tab.get("_size", 14)), pxMode=True)
                it.setGLOptions("translucent")
                self.view.addItem(it)
                self.items.append(it)
            else:
                self._add(q, color, float(tab.get("_width", 2.5)))
        self._grid(span * 1.3, max(5.0, round(span / 10, -1) or 5.0))
        ctr = 0.5 * (lo + hi) * np.array([1.0, 1.0, k])
        self.view.opts["center"] = pg.Vector(ctr[0], ctr[1], ctr[2])
        self.view.setCameraPosition(distance=1.5 * span, elevation=25, azimuth=-60)
        self.leg.setText("&nbsp;&nbsp;".join(legend) +
                         f"<br><i>eixos: {escape(s.xlabel)}, {escape(s.ylabel)}, {escape(s.z)} (altura exagerada ×{k:g})</i>")


class LivePlots(QtWidgets.QWidget):
    def __init__(self, specs: list[PlotSpec], columns: int = 1, row_height: int = 560, parent=None):
        """um gráfico embaixo do outro (columns > 1: em grade), cada um com `row_height` px"""
        super().__init__(parent)
        self.specs = specs
        lay = QtWidgets.QGridLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.widgets: dict[str, QtWidgets.QWidget] = {}
        self.plots: dict[str, pg.PlotItem] = {}
        self.legends: dict[str, pg.LegendItem] = {}
        self._buf: dict[str, list[np.ndarray]] = {}
        h = row_height or 560
        for i, s in enumerate(specs):
            try:
                w = _Plot3D(s, max(h, 640)) if s.kind == "3d" else _Plot2D(s, h, 3 if columns == 1 else 2)
            except Exception:                     # sem OpenGL: a trajetória vira a vista de cima
                w = _Plot2D(PlotSpec(s.key, s.title + " (vista de cima — sem OpenGL)", s.x, s.ys, s.xlabel,
                                     s.ylabel, s.live, s.source, aspect=True, live_ys=s.live_ys), h)
            lay.addWidget(w, i // columns, i % columns)
            self.widgets[s.key] = w
            if isinstance(w, _Plot2D):
                self.plots[s.key] = w.plot
                self.legends[s.key] = w.legend

    @property
    def curves(self) -> dict:
        return {(k, y): c for k, w in self.widgets.items() if isinstance(w, _Plot2D) for y, c in w.live.items()}

    # ------------------------------------------------------------------ tempo real
    def clear(self) -> None:
        self._buf = {}
        for s in self.specs:
            w = self.widgets[s.key]
            if isinstance(w, _Plot3D):
                w.clear_final()
                w._grid()
            elif s.source != "log":
                ys = s.live_ys
                w.clear_final()
                for j, y in enumerate(ys):
                    c = w.plot.plot([], [], pen=_pen(PALETTE[j % len(PALETTE)], 1.6), connect="finite")
                    w.legend.addItem(c, tex(y))
                    w.live[y] = c
        for c in self.curves.values():
            c.setData([], [])

    def append(self, chunk) -> None:
        """acumula um pedaço do registro; quebra a linha quando o tempo volta (outra corrida)"""
        if not len(chunk):
            return
        t = chunk["t"]
        if "t" in self._buf and self._buf["t"] and t[0] < self._buf["t"][-1][-1]:
            for k in self._buf:
                self._buf[k].append(np.array([np.nan]))
        for k in chunk.keys():
            self._buf.setdefault(k, []).append(chunk[k])

    def redraw(self) -> None:
        cache = {}

        def col(name):
            if name not in cache:
                arrs = self._buf.get(name)
                if not arrs:
                    return None
                a = np.concatenate(arrs)
                cache[name] = np.degrees(a) if is_angle(name) else a
            return cache[name]
        for s in self.specs:
            w = self.widgets[s.key]
            if isinstance(w, _Plot3D):
                if s.live and col(s.x) is not None and col(s.ys[0]) is not None and col(s.z) is not None:
                    n = len(col(s.x))
                    st = max(1, n // 20000)
                    w.set_live(col(s.x)[::st], col(s.ys[0])[::st], col(s.z)[::st])
                continue
            xname = s.live_x or s.x
            for y, c in w.live.items():
                xs, ys = col(xname), col(y)
                if xs is None or ys is None:
                    continue
                if y == "pk_n":         # carga: só depois de solta
                    ys = np.where(col("pk_h") > 0, ys, np.nan) if col("pk_h") is not None else ys
                    xs = col("pk_e") if xname == "e" else xs
                n = min(len(xs), len(ys))
                step = max(1, n // 20000)
                c.setData(xs[:n:step], ys[:n:step])

    # ------------------------------------------------------------------ resultado final
    def show_result(self, res: SimResult) -> None:
        if res.log is not None and len(res.log):
            self._buf = {k: [res.log[k]] for k in res.log.keys()}
            self.redraw()
        for s in self.specs:
            if s.source == "log":
                continue
            w = self.widgets[s.key]
            w.clear_final()
            w.draw_tables(res)


def format_value(v) -> str:
    if isinstance(v, float):
        if math.isnan(v):
            return "—"
        return f"{v:.4g}"
    if isinstance(v, (list, tuple)):
        return ", ".join(format_value(x) for x in v)
    if isinstance(v, dict):
        return "; ".join(f"{k}: {format_value(x)}" for k, x in v.items())
    if isinstance(v, (np.floating, np.integer)):
        return format_value(float(v))
    return str(v)
