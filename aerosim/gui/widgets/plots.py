"""Grade de gráficos em tempo real (pyqtgraph) montada a partir das PlotSpec da simulação."""
from __future__ import annotations

import math

import numpy as np
import pyqtgraph as pg
from PyQt6 import QtWidgets

from aerosim.interfaces.simulation import PlotSpec, SimResult

# canais em radianos no registro: mostrados em graus
ANGLES = {"phi", "theta", "psi", "p", "q", "r", "alpha", "beta", "gamma", "chi", "thc", "alc", "phic", "de", "da",
          "dr", "dw"}
PALETTE = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf", "#e377c2", "#7f7f7f"]

pg.setConfigOptions(antialias=True, background="w", foreground="k")


def is_angle(ch: str) -> bool:
    return ch in ANGLES or ch.startswith("slosh_")


class LivePlots(QtWidgets.QWidget):
    def __init__(self, specs: list[PlotSpec], columns: int = 2, row_height: int = 0, parent=None):
        """row_height > 0: altura fixa por linha de gráficos (a aba rola); a legenda fica embaixo de
        cada gráfico, fora da área das curvas"""
        super().__init__(parent)
        self.specs = specs
        self.lay = pg.GraphicsLayoutWidget()
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self.lay)
        rows = max(1, math.ceil(len(specs) / columns))
        if row_height > 0:
            self.lay.setMinimumHeight(rows * row_height)
        self.plots: dict[str, pg.PlotItem] = {}
        self.legends: dict[str, pg.LegendItem] = {}
        self.curves: dict[tuple[str, str], pg.PlotDataItem] = {}
        self._buf: dict[str, list[np.ndarray]] = {}
        for i, s in enumerate(specs):
            cell = self.lay.addLayout(row=i // columns, col=i % columns)
            p = cell.addPlot(row=0, col=0, title=f"<b>{s.title}</b>")
            p.showGrid(x=True, y=True, alpha=0.3)
            p.setLabel("bottom", s.xlabel)
            p.setLabel("left", s.ylabel)
            for ax in ("bottom", "left"):
                p.getAxis(ax).enableAutoSIPrefix(False)
            leg = pg.LegendItem(colCount=3, labelTextSize="8pt", horSpacing=14, verSpacing=-4)
            cell.addItem(leg, row=1, col=0)
            cell.layout.setRowStretchFactor(0, 10)
            self.plots[s.key] = p
            self.legends[s.key] = leg
            if s.source == "log":
                for j, y in enumerate(s.ys):
                    c = p.plot([], [], pen=pg.mkPen(PALETTE[j % len(PALETTE)], width=1.6), connect="finite")
                    leg.addItem(c, y)
                    self.curves[(s.key, y)] = c
            if s.key == "xy" or (s.x == "e" and "n" in s.ys):
                p.setAspectLocked(True)

    # ------------------------------------------------------------------ tempo real
    def clear(self) -> None:
        self._buf = {}
        for s in self.specs:
            p = self.plots[s.key]
            if s.source != "log":
                p.clear()
                self.legends[s.key].clear()
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
        for (key, y), c in self.curves.items():
            s = next(sp for sp in self.specs if sp.key == key)
            xs, ys = col(s.x), col(y)
            if xs is None or ys is None:
                continue
            if y == "pk_n":         # carga: só depois de solta
                ys = np.where(col("pk_h") > 0, ys, np.nan) if col("pk_h") is not None else ys
                xs = col("pk_e") if s.x == "e" else xs
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
            p = self.plots[s.key]
            p.clear()
            leg = self.legends[s.key]
            leg.clear()
            name = s.source.split(":", 1)[1]
            if name.endswith("*"):
                tables = [(k, v) for k, v in res.series.items() if k.startswith(name[:-1])]
            else:
                tables = [(name, res.series.get(name))]
            many = len(tables) > 1 or name.endswith("*")
            k = 0
            for tname, tab in tables:
                if not tab or s.x not in tab:
                    continue
                for y in s.ys:
                    if y not in tab:
                        continue
                    xs = np.asarray(tab[s.x], float)
                    ys = np.asarray(tab[y], float)
                    # tabelas por prefixo ("me_CG atual"): o nome depois do prefixo é o rótulo
                    rest = tname[len(name) - 1:] if name.endswith("*") else tname
                    lab = (f"{rest}: {y}" if len(s.ys) > 1 else rest) if many else y
                    if s.swap:
                        xs, ys = ys, xs
                    color = tab.get("_color") if isinstance(tab, dict) and tab.get("_color") else PALETTE[k % len(PALETTE)]
                    k += 1
                    dash = tab.get("_dash") if isinstance(tab, dict) else None
                    fill = tab.get("_fill") if isinstance(tab, dict) else None
                    if fill and fill in tab:          # região sombreada entre y e a coluna `_fill`
                        y2 = np.asarray(tab[fill], float)
                        c1 = pg.PlotDataItem(xs, ys, pen=pg.mkPen(color, width=1))
                        c2 = pg.PlotDataItem(xs, y2, pen=pg.mkPen(None))
                        col = pg.mkColor(color)
                        col.setAlpha(110 if tab.get("_strong") else 45)
                        it = pg.FillBetweenItem(c1, c2, brush=pg.mkBrush(col))
                        p.addItem(c1)
                        p.addItem(c2)
                        p.addItem(it)
                        leg.addItem(c1, lab)
                        continue
                    if isinstance(tab, dict) and tab.get("_marker"):
                        it = p.plot(xs, ys, pen=None, symbol="o", symbolSize=11, symbolBrush=color)
                    elif dash:
                        it = p.plot(xs, ys, pen=pg.mkPen(color, width=1.4, style=pg.QtCore.Qt.PenStyle.DashLine))
                    elif s.scatter:
                        it = p.plot(xs, ys, pen=pg.mkPen(color, width=1, style=pg.QtCore.Qt.PenStyle.DashLine),
                                    symbol="o", symbolSize=7, symbolBrush=color)
                    else:
                        it = p.plot(xs, ys, pen=pg.mkPen(color, width=1.8))
                    leg.addItem(it, lab)


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
