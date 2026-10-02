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
    def __init__(self, specs: list[PlotSpec], columns: int = 2, parent=None):
        super().__init__(parent)
        self.specs = specs
        self.lay = pg.GraphicsLayoutWidget()
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self.lay)
        self.plots: dict[str, pg.PlotItem] = {}
        self.curves: dict[tuple[str, str], pg.PlotDataItem] = {}
        self._buf: dict[str, list[np.ndarray]] = {}
        for i, s in enumerate(specs):
            p = self.lay.addPlot(row=i // columns, col=i % columns, title=s.title)
            p.showGrid(x=True, y=True, alpha=0.3)
            p.setLabel("bottom", s.xlabel)
            p.setLabel("left", s.ylabel)
            p.addLegend(offset=(5, 5), labelTextSize="8pt")
            self.plots[s.key] = p
            if s.source == "log":
                for j, y in enumerate(s.ys):
                    self.curves[(s.key, y)] = p.plot([], [], pen=pg.mkPen(PALETTE[j % len(PALETTE)], width=1.6), name=y,
                                                     connect="finite")
            if s.key == "xy" or (s.x == "e" and "n" in s.ys):
                p.setAspectLocked(True)

    # ------------------------------------------------------------------ tempo real
    def clear(self) -> None:
        self._buf = {}
        for s in self.specs:
            p = self.plots[s.key]
            if s.source != "log":
                p.clear()
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
            name = s.source.split(":", 1)[1]
            tables = res.series.items() if name == "*" else [(name, res.series.get(name))]
            k = 0
            for tname, tab in tables:
                if not tab or s.x not in tab:
                    continue
                for y in s.ys:
                    if y not in tab:
                        continue
                    xs = np.asarray(tab[s.x], float)
                    ys = np.asarray(tab[y], float)
                    lab = f"{tname}: {y}" if name == "*" else y
                    color = PALETTE[k % len(PALETTE)]
                    k += 1
                    if s.scatter:
                        p.plot(xs, ys, pen=pg.mkPen(color, width=1, style=pg.QtCore.Qt.PenStyle.DashLine),
                               symbol="o", symbolSize=7, symbolBrush=color, name=lab)
                    else:
                        p.plot(xs, ys, pen=pg.mkPen(color, width=1.8), name=lab)


def format_value(v) -> str:
    if isinstance(v, float):
        if math.isnan(v):
            return "—"
        return f"{v:.4g}"
    if isinstance(v, (list, tuple)):
        return ", ".join(format_value(x) for x in v)
    return str(v)
