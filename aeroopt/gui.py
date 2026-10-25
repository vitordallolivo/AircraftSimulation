"""A janela do aeroopt: montar o problema, rodar o processo em etapas e acompanhar o que acontece.

    python -m aeroopt [projeto.json] [problema.opt.json]
    python -m aeroopt --exemplo                 # um projeto de exemplo, para ver a janela funcionando

Esquerda, de cima para baixo: o projeto da sprint de onde saem os rascunhos, a pontuação (tudo o que o .toml do
regulamento tem: entradas, constantes, faixas, termos, nota e validade, editável e gravável), o problema em quatro
botões que abrem submenus (variáveis com os limites, restrições, perfis por região, motores, hélices e baterias por
marcação), as categorias de avião que a busca pode montar e as opções das etapas.

Direita, atualizada a cada candidato que termina uma etapa (não a cada passo: o bastante para ver a busca andar):
o andamento de cada etapa, o MTOW de cada ponto de projeto avaliado, a nota de cada configuração, o mapa dos
aviões (PV × carga paga, com as linhas de eficiência estrutural constante e a cor pela nota), a tabela das
configurações e, do avião clicado, o 3D e a nota fator por fator.

As contas são do núcleo (o ponto de projeto, o 6GDL, a nota, as gerações); a janela só chama o `GenerationsSolver`
(as configurações saem das gerações; com poucas combinações, todas numa geração) e desenha.
"""
from __future__ import annotations

import copy
import math
import os
import threading
import traceback

import numpy as np
import pyqtgraph as pg
from PyQt6 import QtCore, QtWidgets

import aeroopt
from aerosim.design import registry as rg

from . import categories as cat
from . import scoring as sc
from . import stages as sg
from .generations import GenerationsSolver

OK_C, BAD_C, BEST_C = "#2ca02c", "#d62728", "#1f4e8c"
SIMPLE = ("MTOW", "EE")                       # objetivos simples, sem arquivo
EE_LINES = (0.5, 1.0, 1.5, 2.0, 3.0)
AXES = {"PV (kg)": "pv", "carga paga (kg)": "cp", "MTOW (kg)": "mtow_f", "EE": "ee", "nota": "nota",
        "envergadura (m)": "b", "bateria (kg)": "m_bat"}


def _plot(xlabel: str, ylabel: str, legend: bool = True):
    from aerosim.gui.design.mdo_page import LegendPlot
    w = LegendPlot(xlabel, ylabel, cols=3, legend=legend)
    w.setMinimumHeight(300)
    return w


def _section(lay, title: str):
    lab = QtWidgets.QLabel(f"<b>{title}</b>")
    lab.setStyleSheet("font-size:13px; color:#1f2d3d; border-bottom:1px solid #c9d3e0; padding-bottom:2px")
    lay.addWidget(lab)


def _table(headers: list[str]) -> QtWidgets.QTableWidget:
    t = QtWidgets.QTableWidget(0, len(headers))
    t.setHorizontalHeaderLabels(headers)
    t.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
    t.verticalHeader().setVisible(False)
    return t


def _set_rows(t: QtWidgets.QTableWidget, rows: list[list], editable: bool = True) -> None:
    t.setRowCount(len(rows))
    for i, r in enumerate(rows):
        for j, v in enumerate(r):
            it = QtWidgets.QTableWidgetItem(str(v))
            if not editable:
                it.setFlags(it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
            t.setItem(i, j, it)


def _fit(t: QtWidgets.QTableWidget, extra: int = 1) -> None:
    """altura da tabela para as linhas que ela tem (mais `extra` em branco, para acrescentar)"""
    h = t.horizontalHeader().height() + 4 + sum(t.rowHeight(i) for i in range(t.rowCount()))
    t.setFixedHeight(h + extra * (t.verticalHeader().defaultSectionSize()))


def _fit_range(plot, xs, ys, pad: float = 0.08) -> None:
    """os eixos do gráfico para os pontos que ele tem (refeito a cada ponto que chega)"""
    xs = [x for x in xs if math.isfinite(x)]
    ys = [y for y in ys if math.isfinite(y)]
    if not xs or not ys:
        return
    for (lo, hi), fn in (((min(xs), max(xs)), plot.setXRange), ((min(ys), max(ys)), plot.setYRange)):
        d = (hi - lo) * pad or max(abs(hi) * pad, 0.5)
        fn(lo - d, hi + d, padding=0)


def _cells(t: QtWidgets.QTableWidget) -> list[list[str]]:
    return [[(t.item(i, j).text() if t.item(i, j) else "").strip() for j in range(t.columnCount())]
            for i in range(t.rowCount())]


def _fmt(v) -> str:
    return rg.fmt(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else str(v)


# ------------------------------------------------------------------ pontuação: tudo o que o .toml tem
class ScoringEditor(QtWidgets.QWidget):
    """o arquivo de pontuação em campos: o que se muda aqui vale na próxima rodada e pode ser gravado"""

    def __init__(self, parent=None):
        super().__init__(parent)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        h = QtWidgets.QHBoxLayout()
        self.combo = QtWidgets.QComboBox()
        files = sorted(f[:-5] for f in os.listdir(sc.PONTUACAO) if f.endswith(".toml"))
        self.combo.addItems(files + list(SIMPLE))
        self.combo.currentTextChanged.connect(self.load)
        h.addWidget(self.combo, 1)
        self.open_b = QtWidgets.QPushButton("Abrir…")
        self.open_b.clicked.connect(self._open)
        h.addWidget(self.open_b)
        v.addLayout(h)
        self.head = QtWidgets.QLabel()
        self.head.setWordWrap(True)
        self.head.setStyleSheet("color:#334")
        v.addWidget(self.head)
        self.inputs = QtWidgets.QLabel()
        self.inputs.setWordWrap(True)
        v.addWidget(self.inputs)
        self.consts = _table(["constante", "valor"])
        self.tiers = _table(["faixa", "grandeza", "limites", "valores", "fora"])
        self.terms = _table(["termo", "expressão"])
        self.valid = _table(["validade: expressão", "op", "valor", "fonte"])
        self.score = QtWidgets.QLineEdit()
        for lab, w in (("constantes", self.consts), ("faixas (degraus)", self.tiers),
                       ("termos, em ordem (cada um usa os de cima)", self.terms), ("nota", self.score),
                       ("condições de voo válido", self.valid)):
            v.addWidget(QtWidgets.QLabel(f"<i>{lab}</i>"))
            v.addWidget(w)
        b = QtWidgets.QHBoxLayout()
        self.check_b = QtWidgets.QPushButton("Conferir no núcleo")
        self.check_b.setToolTip("traduz os campos para o programa da nota e o núcleo confere")
        self.save_b = QtWidgets.QPushButton("Gravar .toml…")
        self.check_b.clicked.connect(self._check)
        self.save_b.clicked.connect(self._save)
        b.addWidget(self.check_b)
        b.addWidget(self.save_b)
        v.addLayout(b)
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        v.addWidget(self.msg)
        self.data: dict = {}
        self.load(self.combo.currentText())

    def set_spec(self, spec: str) -> None:
        name = os.path.basename(spec)[:-5] if spec.endswith(".toml") else spec
        if self.combo.findText(name) < 0:
            self.combo.addItem(name)
        self.combo.setCurrentText(name)
        self.load(spec)

    def _open(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Pontuação", sc.PONTUACAO, "pontuação (*.toml)")
        if path:
            self.set_spec(path)

    def load(self, spec: str) -> None:
        simple = spec in SIMPLE
        for w in (self.consts, self.tiers, self.terms, self.valid, self.score, self.check_b, self.save_b):
            w.setEnabled(not simple)
        if simple:
            self.data = {}
            self.head.setText(f"objetivo simples: maximizar {spec}")
            self.inputs.setText("")
            for t in (self.consts, self.tiers, self.terms, self.valid):
                t.setRowCount(0)
            self.score.setText("")
            return
        d = sc.ScoringFile(spec).data
        self.data = d
        self.head.setText(f"<b>{d.get('nome', spec)}</b><br>{d.get('fonte', '')}")
        self.inputs.setText("entradas (o avaliador entrega, em SI): <code>" + ", ".join(d.get("entradas", [])) +
                            "</code>")
        _set_rows(self.consts, [[k, v] for k, v in d.get("constantes", {}).items()])
        _set_rows(self.tiers, [[k, t["grandeza"], ", ".join(f"{x:g}" for x in t["limites"]),
                                ", ".join(f"{x:g}" for x in t["valores"]), t.get("fora", 0.0)]
                               for k, t in d.get("faixas", {}).items()])
        _set_rows(self.terms, [[k, v] for k, v in d.get("termos", {}).items()])
        self.score.setText(d.get("nota", {}).get("expressao", ""))
        _set_rows(self.valid, [[x["expressao"], x["op"], x["valor"], x.get("fonte", "")]
                               for x in d.get("validade", [])])
        for t in (self.consts, self.tiers, self.terms, self.valid):
            _fit(t)
        self.msg.setText("")

    def fields(self) -> dict:
        """os campos de volta num dicionário de pontuação"""
        d = copy.deepcopy(self.data)
        nums = lambda s: [float(x) for x in s.replace(";", ",").split(",") if x.strip()]
        d["constantes"] = {k: float(v) for k, v in _cells(self.consts) if k}
        d["faixas"] = {r[0]: dict(grandeza=r[1], limites=nums(r[2]), valores=nums(r[3]), fora=float(r[4] or 0))
                       for r in _cells(self.tiers) if r[0]}
        d["termos"] = {k: v for k, v in _cells(self.terms) if k}
        d["nota"] = dict(expressao=self.score.text().strip())
        d["validade"] = [dict(expressao=r[0], op=r[1], valor=float(r[2] or 0), **({"fonte": r[3]} if r[3] else {}))
                         for r in _cells(self.valid) if r[0]]
        return d

    def scoring(self):
        """a pontuação como está nos campos (erro de escrita vira `ScoringError`)"""
        if self.combo.currentText() in SIMPLE:
            return sc.scoring_for(self.combo.currentText())
        return sc.ScoringFile(path=self.combo.currentText(), data=self.fields())

    def spec(self) -> str:
        return self.combo.currentText()

    def _check(self):
        try:
            s = self.scoring()
            from aerosim.backend.zig import ZigBackend
            row = {q: 1.0 for q in s.quantities()}
            sc.evaluate(s, row, ZigBackend())
            p = s.program()
            self.msg.setText(f"✔ {len(p['ops'])} operações, {len(p['slots'])} vagas: o núcleo aceita")
        except Exception as e:  # noqa: BLE001 — o texto do erro vai para o usuário
            self.msg.setText(f"<span style='color:{BAD_C}'>✖ {e}</span>")

    def _save(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Gravar pontuação", sc.PONTUACAO, "pontuação (*.toml)")
        if path:
            with open(path, "w", encoding="utf-8") as f:
                f.write(sc.to_toml(self.fields()))
            self.msg.setText(f"gravado: {path}")


# ------------------------------------------------------------------ variáveis: livre, limite inferior e superior
AREAS = (("wing.airfoil", "asa (raiz)"), ("wing.airfoil_tip", "asa (ponta)"), ("tail.airfoil", "EH"),
         ("tail.vairfoil", "EV"))
PARTS = (("power.motor", "motores"), ("power.propeller", "hélices"), ("power.battery", "baterias"),
         ("power.layout", "arranjo dos motores"))
LIB_KEYS = tuple(k for k, _ in AREAS + PARTS)


def _label(key: str) -> str:
    if key in rg.INPUTS:
        return rg.INPUTS[key].label
    return sg.EXTRA_INPUTS[key][1] if key in sg.EXTRA_INPUTS else key


def _variable(pr, key: str):
    """a variável de lista do problema (criada fixa se o problema ainda não tem)"""
    v = next((v for v in pr.variables if v.key == key), None)
    if v is None:
        from aerosim.interfaces.optim import OptVariable
        v = OptVariable(key, "lista", group="asa" if key.startswith("wing") else
                        "cauda" if key.startswith("tail") else "propulsão")
        pr.variables.append(v)
    return v


class VariablesTable(QtWidgets.QTableWidget):
    """as variáveis numéricas (contínuas e inteiras), como os lb/ub do MDO antigo: livre ou fixa, o valor do avião
    e os limites. As listas (perfis, motores, hélices, baterias) se escolhem nas listas próprias, por marcação"""
    COLS = ["livre", "variável", "grupo", "valor do avião", "limite inferior", "limite superior"]

    def __init__(self, parent=None):
        super().__init__(0, len(self.COLS), parent)
        self.setHorizontalHeaderLabels(self.COLS)
        self.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.verticalHeader().setVisible(False)
        self.keys: list[str] = []

    @staticmethod
    def _spin(v, x: float):
        if v.kind == "inteira":
            s = QtWidgets.QSpinBox()
            s.setRange(0, 64)
            s.setValue(round(x))
        else:
            s = QtWidgets.QDoubleSpinBox()
            s.setRange(-1e4, 1e4)
            s.setDecimals(3)
            s.setSingleStep(0.05)
            s.setValue(x)
        return s

    def set_problem(self, pr, project=None) -> None:
        vs = [v for v in pr.variables if v.kind != "lista"]
        self.keys = [v.key for v in vs]
        self.setRowCount(0)                          # os campos de antes saem junto com as linhas
        self.setRowCount(len(vs))
        for i, v in enumerate(vs):
            box = QtWidgets.QTableWidgetItem()
            box.setCheckState(QtCore.Qt.CheckState.Checked if v.free else QtCore.Qt.CheckState.Unchecked)
            self.setItem(i, 0, box)
            unit = rg.INPUTS[v.key].unit if v.key in rg.INPUTS else ""
            now = sg.get_value(project, v.key) if project is not None else ""
            for j, txt in ((1, _label(v.key) + (f" ({unit})" if unit else "")), (2, v.group), (3, _fmt(now))):
                it = QtWidgets.QTableWidgetItem(txt)
                it.setFlags(it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
                it.setToolTip(v.key)
                self.setItem(i, j, it)
            self.setCellWidget(i, 4, self._spin(v, v.lo))
            self.setCellWidget(i, 5, self._spin(v, v.hi))

    def read_into(self, pr) -> None:
        for i, key in enumerate(self.keys):
            v = next((v for v in pr.variables if v.key == key), None)
            if v is None:
                continue
            v.free = self.item(i, 0).checkState() == QtCore.Qt.CheckState.Checked
            lo, hi = float(self.cellWidget(i, 4).value()), float(self.cellWidget(i, 5).value())
            v.lo, v.hi = min(lo, hi), max(lo, hi)


# ------------------------------------------------------------------ restrições
class ConstraintsTable(QtWidgets.QWidget):
    """as restrições do problema, como em Condições e restrições do aerosim: ligada, grandeza, operador, valor.
    A pista (s_to) e o MTOW definem a busca (o MTOW é o que corre na pista); as outras barram o ponto de projeto.
    Envergadura, área e nº de motores não aparecem aqui: são variáveis, e o limite delas fica na tabela das
    variáveis (`problem.fold_bounds`)"""
    COLS = ["ligada", "grandeza", "op", "valor"]

    def __init__(self, parent=None):
        super().__init__(parent)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        self.t = QtWidgets.QTableWidget(0, len(self.COLS))
        self.t.setHorizontalHeaderLabels(self.COLS)
        self.t.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.t.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.t.verticalHeader().setVisible(False)
        v.addWidget(self.t)
        h = QtWidgets.QHBoxLayout()
        self.add_cb = QtWidgets.QComboBox()
        for k, q in rg.QUANTITIES.items():
            if k not in rg.CONSTRAINT_INPUT:
                self.add_cb.addItem(f"{q.label} ({q.unit})" if q.unit else q.label, k)
        b = QtWidgets.QPushButton("+ restrição")
        b.clicked.connect(lambda: self._add(self.add_cb.currentData(), "≤", 0.0, True))
        r = QtWidgets.QPushButton("− tirar a selecionada")
        r.clicked.connect(lambda: self.t.removeRow(self.t.currentRow()) if self.t.currentRow() >= 0 else None)
        h.addWidget(self.add_cb, 1)
        h.addWidget(b)
        h.addWidget(r)
        v.addLayout(h)

    def _add(self, key: str, op: str, value: float, active: bool) -> None:
        if key in rg.CONSTRAINT_INPUT:
            return
        i = self.t.rowCount()
        self.t.insertRow(i)
        box = QtWidgets.QTableWidgetItem()
        box.setCheckState(QtCore.Qt.CheckState.Checked if active else QtCore.Qt.CheckState.Unchecked)
        self.t.setItem(i, 0, box)
        q = rg.QUANTITIES.get(key)
        it = QtWidgets.QTableWidgetItem(f"{q.label} ({q.unit})" if q and q.unit else (q.label if q else key))
        it.setData(QtCore.Qt.ItemDataRole.UserRole, key)
        it.setFlags(it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
        self.t.setItem(i, 1, it)
        cb = QtWidgets.QComboBox()
        cb.addItems(["≤", "≥", "="])
        cb.setCurrentText(op)
        self.t.setCellWidget(i, 2, cb)
        s = QtWidgets.QDoubleSpinBox()
        s.setRange(-1e6, 1e6)
        s.setDecimals(3)
        s.setValue(value)
        self.t.setCellWidget(i, 3, s)

    def set_problem(self, pr) -> None:
        self.t.setRowCount(0)
        for c in pr.constraints:
            self._add(c.key, c.op, c.value, c.active)

    def read_into(self, pr) -> None:
        from aerosim.interfaces.optim import OptConstraint
        old = {c.key: c for c in pr.constraints}
        out = []
        for i in range(self.t.rowCount()):
            key = self.t.item(i, 1).data(QtCore.Qt.ItemDataRole.UserRole)
            out.append(OptConstraint(key, self.t.cellWidget(i, 2).currentText(), float(self.t.cellWidget(i, 3).value()),
                                     self.t.item(i, 0).checkState() == QtCore.Qt.CheckState.Checked,
                                     old[key].tol if key in old else 0.02))
        pr.constraints = out


# ------------------------------------------------------------------ listas: perfis por região, motores, hélices...
class ChoiceLists(QtWidgets.QWidget):
    """uma lista marcável por variável de lista, lado a lado, puxada do que existe (os perfis do projeto e da pasta
    de perfis, o catálogo de motores, hélices e baterias). Nada marcado: a lista fica no valor do avião (em
    negrito); marcado: a busca varre os marcados, e cada lista marcada vira um eixo das configurações"""

    def __init__(self, keys, airfoils: bool = False, parent=None):
        super().__init__(parent)
        self.keys = dict(keys)
        v = QtWidgets.QVBoxLayout(self)
        self.note = QtWidgets.QLabel("marque o que a busca pode escolher em cada lista; nada marcado = o do avião "
                                     "(em negrito)")
        self.note.setWordWrap(True)
        top = QtWidgets.QHBoxLayout()
        top.addWidget(self.note, 1)
        if airfoils:
            b = QtWidgets.QPushButton("Adicionar .dat…")
            b.clicked.connect(self._add_dat)
            top.addWidget(b)
        v.addLayout(top)
        h = QtWidgets.QHBoxLayout()
        self.lists: dict[str, QtWidgets.QListWidget] = {}
        for key, label in self.keys.items():
            col = QtWidgets.QVBoxLayout()
            col.addWidget(QtWidgets.QLabel(f"<b>{label}</b>"))
            lw = QtWidgets.QListWidget()
            lw.setMinimumSize(170, 320)
            self.lists[key] = lw
            col.addWidget(lw)
            row = QtWidgets.QHBoxLayout()
            for txt, st in (("todos", QtCore.Qt.CheckState.Checked), ("nenhum", QtCore.Qt.CheckState.Unchecked)):
                b = QtWidgets.QPushButton(txt)
                b.clicked.connect(lambda _=False, lw=lw, st=st: [lw.item(i).setCheckState(st) for i in range(lw.count())])
                row.addWidget(b)
            col.addLayout(row)
            h.addLayout(col)
        v.addLayout(h)
        self.project, self.added = None, []

    def set_problem(self, pr, project, catalog=None) -> None:
        self.project = project
        for key, lw in self.lists.items():
            lw.clear()
            v = next((v for v in pr.variables if v.key == key), None)
            now = sg.get_value(project, key)
            for n in sg.available(project, key, catalog):
                it = QtWidgets.QListWidgetItem(n + ("  (acrescentado)" if n in self.added else ""))
                it.setData(QtCore.Qt.ItemDataRole.UserRole, n)
                it.setFlags(it.flags() | QtCore.Qt.ItemFlag.ItemIsUserCheckable)
                on = v is not None and v.free and (n in v.options or not v.options)
                it.setCheckState(QtCore.Qt.CheckState.Checked if on else QtCore.Qt.CheckState.Unchecked)
                if n == now:
                    f = it.font()
                    f.setBold(True)
                    it.setFont(f)
                    it.setToolTip("o do avião")
                lw.addItem(it)

    def checked(self, key: str) -> list[str]:
        lw, on = self.lists[key], QtCore.Qt.CheckState.Checked
        return [lw.item(i).data(QtCore.Qt.ItemDataRole.UserRole) for i in range(lw.count())
                if lw.item(i).checkState() == on]

    def tick(self, key: str, names) -> None:
        lw = self.lists[key]
        for i in range(lw.count()):
            if lw.item(i).data(QtCore.Qt.ItemDataRole.UserRole) in names:
                lw.item(i).setCheckState(QtCore.Qt.CheckState.Checked)

    def read_into(self, pr) -> None:
        for key in self.lists:
            names = self.checked(key)
            if names or any(v.key == key for v in pr.variables):
                v = _variable(pr, key)
                v.free, v.options = bool(names), names

    def add_dat(self, path: str) -> str:
        """lê o .dat e põe o perfil no projeto e em todas as listas (desmarcado, as marcas de antes ficam);
        devolve o nome"""
        from aerosim.design import airfoils as afm
        from aerosim.interfaces.optim import OptProblem
        pr = OptProblem()
        e = afm.entry(afm.from_dat(path))
        if self.project.airfoil(e.name) is None:
            self.project.airfoils.append(e)
        self.added.append(e.name)
        self.read_into(pr)
        self.set_problem(pr, self.project)
        return e.name

    def _add_dat(self):
        paths, _ = QtWidgets.QFileDialog.getOpenFileNames(self, "Perfis", "", "perfil (*.dat *.txt)")
        for p in paths:
            try:
                name = self.add_dat(p)
                self.note.setText(f"perfil acrescentado: {name}. Marque as regiões em que ele pode ir")
            except Exception as e:  # noqa: BLE001
                self.note.setText(f"<span style='color:{BAD_C}'>{os.path.basename(p)}: {e}</span>")


class _Menu(QtWidgets.QDialog):
    """o submenu aberto por um botão da esquerda: o editor, OK aplica, Cancelar desfaz"""

    def __init__(self, title: str, body: QtWidgets.QWidget, parent=None, top: QtWidgets.QWidget | None = None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(900, 620)
        v = QtWidgets.QVBoxLayout(self)
        if top is not None:
            v.addWidget(top, 0)
        v.addWidget(body, 1)
        bb = QtWidgets.QDialogButtonBox(QtWidgets.QDialogButtonBox.StandardButton.Ok |
                                        QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        v.addWidget(bb)


# ------------------------------------------------------------------ contas fora da linha da janela
class _Worker(QtCore.QObject):
    progress = QtCore.pyqtSignal(float, str)
    item = QtCore.pyqtSignal(str, object)
    done = QtCore.pyqtSignal(object)
    failed = QtCore.pyqtSignal(str)

    def __init__(self, fn):
        super().__init__()
        self.fn = fn

    def run(self):
        try:
            self.done.emit(self.fn(self))
        except Exception:  # noqa: BLE001 — o rastro vai para a janela
            self.failed.emit(traceback.format_exc(limit=5))


class AeroOptWindow(QtWidgets.QMainWindow):
    def __init__(self, project=None, problem=None, path: str = ""):
        super().__init__()
        self.setWindowTitle("aeroopt — otimizador do projeto")
        self.resize(1600, 1000)
        self.project, self.path = project, path
        self.problem = problem
        self.rows: dict[str, dict] = {}
        self.points: list[tuple[float, bool, str]] = []      # MTOW de cada ponto avaliado, viável, configuração
        self.order: list[str] = []                           # configurações na ordem em que ganharam nota
        self.funnel: dict[str, list[int]] = {}
        self.selected: str | None = None
        self._threads: list = []
        self._cancel = threading.Event()
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        self.setCentralWidget(split)
        split.addWidget(self._left())
        split.addWidget(self._right())
        split.setSizes([560, 1040])
        if project is None:                          # sem projeto: os rascunhos de um projeto novo da sprint
            from aerosim.design.project import DesignProject
            project = DesignProject()
        self.set_project(project, path, problem)

    # ------------------------------------------------------------------ esquerda: o problema
    def _left(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        _section(v, "Projeto da sprint")
        h = QtWidgets.QHBoxLayout()
        self.proj_lbl = QtWidgets.QLabel("—")
        self.proj_lbl.setWordWrap(True)
        b = QtWidgets.QPushButton("Abrir projeto…")
        b.clicked.connect(self._open_project)
        h.addWidget(self.proj_lbl, 1)
        h.addWidget(b)
        v.addLayout(h)
        h = QtWidgets.QHBoxLayout()
        for txt, fn in (("Abrir problema…", self._open_problem), ("Gravar problema…", self._save_problem)):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            h.addWidget(b)
        v.addLayout(h)
        _section(v, "Pontuação (o .toml do regulamento)")
        self.scoring = ScoringEditor()
        v.addWidget(self.scoring)
        _section(v, "O problema (cada botão abre o submenu)")
        self.vars, self.cons = VariablesTable(), ConstraintsTable()
        self.airfoils, self.parts = ChoiceLists(AREAS, airfoils=True), ChoiceLists(PARTS)
        iso = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(iso)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(QtWidgets.QLabel("isolar:"))
        for g in ("asa", "propulsão", "requisitos", "nenhuma"):
            b = QtWidgets.QPushButton(g)
            b.clicked.connect(lambda _=False, g=g: self._isolate(g))
            h.addWidget(b)
        h.addStretch(1)
        self.menus = {"variáveis": _Menu("Variáveis: livre, limite inferior e superior", self.vars, self, iso),
                      "restrições": _Menu("Restrições (como Condições e restrições do aerosim)", self.cons, self),
                      "perfis": _Menu("Perfis: qual entra em que região", self.airfoils, self),
                      "peças": _Menu("Motores, hélices e baterias do catálogo", self.parts, self)}
        self.summary: dict[str, QtWidgets.QLabel] = {}
        grid = QtWidgets.QGridLayout()
        for i, (k, txt) in enumerate((("variáveis", "Variáveis…"), ("restrições", "Restrições…"),
                                      ("perfis", "Perfis por região…"), ("peças", "Motores, hélices e baterias…"))):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(lambda _=False, k=k: self.open_menu(k))
            lab = QtWidgets.QLabel("—")
            lab.setWordWrap(True)
            lab.setStyleSheet("color:#444")
            self.summary[k] = lab
            grid.addWidget(b, i, 0, QtCore.Qt.AlignmentFlag.AlignTop)
            grid.addWidget(lab, i, 1)
        grid.setColumnStretch(1, 1)
        v.addLayout(grid)
        _section(v, "Categorias de avião")
        grid = QtWidgets.QGridLayout()
        self.cat_cb = {}
        for i, c in enumerate(cat.CATEGORIES):
            cb = QtWidgets.QCheckBox(c)
            cb.setToolTip(", ".join(f"{k} = {x}" for k, x in cat.fields(c).items()))
            self.cat_cb[c] = cb
            grid.addWidget(cb, i // 4, i % 4)
        v.addLayout(grid)
        _section(v, "Etapas")
        f = QtWidgets.QFormLayout()
        self.evals = QtWidgets.QSpinBox()
        self.evals.setRange(1, 200)
        self.evals.setValue(12)
        self.evals.setToolTip("pontos de projeto que a busca das superfícies gasta em cada configuração")
        self.workers = QtWidgets.QSpinBox()
        self.workers.setRange(1, max(os.cpu_count() or 1, 1))
        self.workers.setValue(max(1, (os.cpu_count() or 2) - 1))
        self.six = QtWidgets.QCheckBox("MTOW no 6GDL (mais lento, mais fiel)")
        self.six.setChecked(True)
        f.addRow("avaliações por configuração", self.evals)
        f.addRow("processos por etapa", self.workers)
        self.pop = QtWidgets.QSpinBox()
        self.pop.setRange(2, 256)
        self.pop.setValue(16)
        self.pop.setToolTip("configurações por geração; com menos combinações que isto, roda todas de uma vez")
        self.gens = QtWidgets.QSpinBox()
        self.gens.setRange(1, 500)
        self.gens.setValue(8)
        self.gens.setToolTip("gerações do algoritmo genético (elite, seleção por posição, cruzamento, mutação)")
        f.addRow("configurações por geração", self.pop)
        f.addRow("gerações", self.gens)
        self.geo = QtWidgets.QCheckBox("geometria no núcleo: hélice × peças, massas fora, chão")
        self.geo.setChecked(True)
        self.geo.setToolTip("etapa barata antes das superfícies, e cada ponto de projeto também passa por ela")
        self.rot = QtWidgets.QDoubleSpinBox()
        self.rot.setRange(0.0, 30.0)
        self.rot.setValue(12.0)
        self.rot.setSuffix(" °")
        self.rot.setToolTip("atitude do corpo na rotação da decolagem: girado no trem principal, nada pode bater no chão")
        self.one_piece = QtWidgets.QCheckBox("exigir uma peça só (sem peça solta)")
        self.one_piece.setToolTip("o montador da sprint ainda não põe montantes nem tubos entre asas: biplano, tandem e "
                                  "parasol saem soltos")
        f.addRow(self.geo)
        f.addRow("ângulo de rotação", self.rot)
        f.addRow(self.one_piece)
        f.addRow(self.six)
        v.addLayout(f)
        h = QtWidgets.QHBoxLayout()
        self.run_b = QtWidgets.QPushButton("▶ Otimizar")
        self.stop_b = QtWidgets.QPushButton("■ Parar")
        self.stop_b.setEnabled(False)
        self.run_b.clicked.connect(self.start)
        self.stop_b.clicked.connect(self._cancel.set)
        h.addWidget(self.run_b)
        h.addWidget(self.stop_b)
        v.addLayout(h)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 1000)
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        v.addWidget(self.bar)
        v.addWidget(self.msg)
        v.addStretch(1)
        s = QtWidgets.QScrollArea()
        s.setWidgetResizable(True)
        s.setWidget(w)
        self.left_scroll = s
        return s

    # ------------------------------------------------------------------ direita: o que está acontecendo
    def _right(self):
        body = QtWidgets.QWidget()
        rv = QtWidgets.QVBoxLayout(body)
        rv.setSpacing(16)
        _section(rv, "Andamento das etapas")
        self.stage_tab = _table(["etapa", "entraram", "prontos", "seguiram"])
        self.stage_tab.setFixedHeight(150)
        rv.addWidget(self.stage_tab)
        h = QtWidgets.QHBoxLayout()
        self.eval_plot = _plot("ponto de projeto avaliado", "MTOW na pista (kg)")
        self.pts_ok = pg.ScatterPlotItem(size=6, brush=pg.mkBrush(OK_C), pen=pg.mkPen(None), name="fecha")
        self.pts_bad = pg.ScatterPlotItem(size=6, brush=pg.mkBrush(None), pen=pg.mkPen(BAD_C), name="não fecha")
        self.best_eval = pg.PlotDataItem(pen=pg.mkPen(BEST_C, width=2), name="melhor até aqui")
        for it in (self.pts_ok, self.pts_bad, self.best_eval):
            self.eval_plot.addItem(it)
        self.score_plot = _plot("configuração (ordem de chegada)", "nota")
        self.sc_ok = pg.ScatterPlotItem(size=9, brush=pg.mkBrush(BEST_C), pen=pg.mkPen(None), name="voo válido")
        self.sc_bad = pg.ScatterPlotItem(size=9, brush=pg.mkBrush(None), pen=pg.mkPen(BAD_C), name="voo inválido")
        self.best_score = pg.PlotDataItem(pen=pg.mkPen("#000", width=2), name="melhor até aqui")
        for it in (self.sc_ok, self.sc_bad, self.best_score):
            self.score_plot.addItem(it)
        h.addWidget(self.eval_plot)
        h.addWidget(self.score_plot)
        rv.addLayout(h)
        _section(rv, "Mapa dos aviões")
        h = QtWidgets.QHBoxLayout()
        self.ax_x, self.ax_y = QtWidgets.QComboBox(), QtWidgets.QComboBox()
        for c, d in ((self.ax_x, "PV (kg)"), (self.ax_y, "carga paga (kg)")):
            c.addItems(list(AXES))
            c.setCurrentText(d)
            c.currentTextChanged.connect(lambda *_: self.draw_map())
        h.addWidget(QtWidgets.QLabel("x:"))
        h.addWidget(self.ax_x)
        h.addWidget(QtWidgets.QLabel("y:"))
        h.addWidget(self.ax_y)
        h.addStretch(1)
        self.map_note = QtWidgets.QLabel()
        self.map_note.setStyleSheet("color:#555")
        h.addWidget(self.map_note)
        rv.addLayout(h)
        self.map = _plot("PV (kg)", "carga paga (kg)", legend=False)
        self.map.setMinimumHeight(420)
        rv.addWidget(self.map)
        _section(rv, "Configurações")
        self.cfg_tab = _table(["configuração", "geração", "etapa", "MTOW pista", "MTOW 6GDL", "PV", "nota", "situação"])
        self.cfg_tab.setMinimumHeight(240)
        self.cfg_tab.horizontalHeader().setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.cfg_tab.setSortingEnabled(True)
        self.cfg_tab.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.cfg_tab.cellClicked.connect(lambda r, _c: self.select(self.cfg_tab.item(r, 0).text()))
        rv.addWidget(self.cfg_tab)
        _section(rv, "Avião selecionado")
        h = QtWidgets.QHBoxLayout()
        self.sel_tab = _table(["", "valor"])
        self.sel_tab.setMinimumHeight(380)
        h.addWidget(self.sel_tab, 2)
        try:
            from aerosim.gui.widgets.view3d import AircraftView
            self.view = AircraftView()
            self.view.setMinimumHeight(380)
            h.addWidget(self.view, 3)
        except Exception:  # noqa: BLE001 — sem OpenGL a janela segue sem o 3D
            self.view = None
        rv.addLayout(h)
        h = QtWidgets.QHBoxLayout()
        self.keep_b = QtWidgets.QPushButton("Gravar projeto com este avião…")
        self.keep_b.setToolTip("os valores do avião selecionado vão para os rascunhos das etapas, num projeto novo")
        self.keep_b.setEnabled(False)
        self.keep_b.clicked.connect(self._keep)
        h.addWidget(self.keep_b)
        self.aerosim_b = QtWidgets.QPushButton("Abrir no aerosim (todas as análises)…")
        self.aerosim_b.setToolTip("abre o avião selecionado numa janela do aerosim: polar, estabilidade, desempenho, "
                                  "missão 6GDL, cargas... tudo o que o aerosim tem")
        self.aerosim_b.setEnabled(False)
        self.aerosim_b.clicked.connect(self.open_aerosim)
        h.addWidget(self.aerosim_b)
        self.csv_b = QtWidgets.QPushButton("Exportar CSV…")
        self.csv_b.setToolTip("cada avião avaliado, em ordem, com as variáveis que mudaram nele (avaliacoes.csv), e "
                              "cada configuração com a nota fator por fator (configuracoes.csv)")
        self.csv_b.clicked.connect(self._export)
        h.addWidget(self.csv_b)
        h.addStretch(1)
        rv.addLayout(h)
        s = QtWidgets.QScrollArea()
        s.setWidgetResizable(True)
        s.setWidget(body)
        self.right_scroll = s
        return s

    # ------------------------------------------------------------------ projeto e problema
    def set_project(self, project, path: str = "", problem=None) -> None:
        self.project, self.path = project, path
        self.proj_lbl.setText(os.path.basename(path) if path else "(projeto em memória)")
        if problem is None:
            problem = aeroopt.from_project(project, os.path.basename(path) or "aeroopt")
            problem.scoring = "sae_br_2026_micro"
        self.set_problem(problem)

    def set_problem(self, pr) -> None:
        pr = copy.deepcopy(pr)
        aeroopt.fold_bounds(pr)                     # o que é variável não fica também como restrição
        self.problem = pr
        self._fill(pr)
        self.scoring.set_spec(pr.scoring)
        for c, cb in self.cat_cb.items():
            cb.setChecked(c in (pr.params.get("categorias") or []))

    def _fill(self, pr) -> None:
        """os submenus e os resumos ao lado dos botões, a partir do problema"""
        self.vars.set_problem(pr, self.project)
        self.cons.set_problem(pr)
        self.airfoils.set_problem(pr, self.project)
        self.parts.set_problem(pr, self.project)
        self._summaries(pr)

    def _summaries(self, pr) -> None:
        free = [v for v in pr.variables if v.free and v.kind != "lista"]
        self.summary["variáveis"].setText("; ".join(f"{_label(v.key)} {_fmt(v.lo)}…{_fmt(v.hi)}" for v in free)
                                          or "nenhuma livre: as superfícies ficam como estão")
        cs = [c for c in pr.constraints if c.active]
        self.summary["restrições"].setText("; ".join(
            f"{rg.QUANTITIES[c.key].label if c.key in rg.QUANTITIES else c.key} {c.op} {_fmt(c.value)}" for c in cs)
            or "nenhuma ligada")
        for k, keys in (("perfis", AREAS), ("peças", PARTS)):
            parts = []
            for key, label in keys:
                v = next((v for v in pr.variables if v.key == key and v.free), None)
                parts.append(f"{label}: {', '.join(v.options) if v.options else 'todos'}" if v else
                             f"{label}: o do avião ({sg.get_value(self.project, key) or '—'})")
            self.summary[k].setText("; ".join(parts))

    def open_menu(self, k: str) -> bool:
        """abre o submenu; OK leva o que mudou para o problema, Cancelar volta ao que era"""
        ok = self.menus[k].exec() == QtWidgets.QDialog.DialogCode.Accepted
        if ok:
            self.problem = self.read_problem()
            self._summaries(self.problem)
        else:
            self._fill(self.problem)
        return ok

    def read_problem(self):
        pr = copy.deepcopy(self.problem)
        self.vars.read_into(pr)
        self.airfoils.read_into(pr)
        self.parts.read_into(pr)
        self.cons.read_into(pr)
        pr.scoring = self.scoring.spec()
        pr.evaluator = "etapas"
        pr.params["categorias"] = [c for c, cb in self.cat_cb.items() if cb.isChecked()]
        return pr

    def _isolate(self, g: str):
        pr = self.read_problem()
        if g == "nenhuma":
            for v in pr.variables:
                v.free = False
        else:
            pr.isolate(g)
        self.problem = pr
        self._fill(pr)

    def _open_project(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Projeto da sprint", "", "projeto (*.json)")
        if path:
            from aerosim.design.project import DesignProject
            self.set_project(DesignProject.load(path), path)

    def _open_problem(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Problema", "", "problema (*.opt.json *.json)")
        if path:
            self.set_problem(aeroopt.load(path))

    def _save_problem(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Gravar problema", "", "problema (*.opt.json)")
        if path:
            aeroopt.save(self.read_problem(), path)
            self.msg.setText(f"gravado: {path}")

    # ------------------------------------------------------------------ rodar
    def start(self):
        try:
            scoring = self.scoring.scoring()
            scoring.program()
        except Exception as e:  # noqa: BLE001
            self.msg.setText(f"<span style='color:{BAD_C}'>pontuação: {e}</span>")
            return
        pr = self.read_problem()
        try:
            ax = sg.axes(self.project, pr)
            n_all = math.prod(len(o) for _, o in ax) if ax else 1
        except (ValueError, KeyError) as e:
            self.msg.setText(f"<span style='color:{BAD_C}'>{e}</span>")
            return
        self._cancel.clear()
        self.rows, self.points, self.order, self.funnel = {}, [], [], {}
        self.redraw()
        from aerosim.interfaces.geometry import GeometryParams
        geo = GeometryParams(rotation=self.rot.value(), connected=self.one_piece.isChecked()) \
            if self.geo.isChecked() else False
        ev = sg.StagedEvaluator(self.project, workers=self.workers.value(), six_dof=self.six.isChecked(),
                                evals=self.evals.value(), start_method="spawn", scoring=scoring, geometry=geo)
        stage_names = [s.name for s in ev.stages(self.project, pr)]
        self.funnel = {s: [0, 0, 0] for s in stage_names}
        self._scoring = scoring
        solver = GenerationsSolver(self.pop.value(), self.gens.value())
        plan = (f"{n_all} combinações: todas numa geração" if n_all <= solver.population else
                f"{n_all} combinações: {solver.generations} gerações de {solver.population}")
        self.msg.setText(f"{plan} · etapas: {' → '.join(stage_names)}")

        def job(w):
            return solver.run(pr, ev, lambda f, t: w.progress.emit(f, t), self._cancel.is_set,
                              lambda st, r: w.item.emit(st, r))
        w = _Worker(job)
        w.progress.connect(self._progress)
        w.item.connect(self._item)
        w.done.connect(self._done)
        self._run(w)

    def _run(self, w: _Worker):
        th = QtCore.QThread(self)
        w.moveToThread(th)
        th.started.connect(w.run)
        w.failed.connect(lambda t: self.msg.setText("erro:\n" + t))
        for sig in (w.done, w.failed):
            sig.connect(th.quit)
        th.finished.connect(lambda: self._finished(th))
        self._threads.append((th, w))
        self.run_b.setEnabled(False)
        self.stop_b.setEnabled(True)
        th.start()

    def _finished(self, th):
        self._threads = [(t, w) for t, w in self._threads if t is not th]
        if not self._threads:
            self.run_b.setEnabled(True)
            self.stop_b.setEnabled(False)

    def _progress(self, f: float, txt: str):
        self.bar.setValue(int(1000 * f))
        self.msg.setText(txt)

    def _item(self, stage: str, r: dict):
        """um candidato terminou uma etapa: tabela, pontos e mapa se atualizam"""
        names = list(self.funnel)
        if stage in self.funnel:
            self.funnel[stage][1] += 1
            if names.index(stage) == 0:               # a cada geração entram mais
                self.funnel[stage][0] = max(self.funnel[stage][0], self.funnel[stage][1])
            k = names.index(stage)
            if r["alive"]:
                self.funnel[stage][2] += 1
                if k + 1 < len(names):
                    self.funnel[names[k + 1]][0] += 1
        if stage == "superfícies":
            for h in r["history"]:
                self.points.append((h["mtow"], h["ok"], r["name"]))
        if stage == "nota" and r["name"] not in self.order:
            self.order.append(r["name"])
        self.rows[r["name"]] = r
        self.redraw()

    def _done(self, res):
        for r in res.rows:
            self.rows[r["name"]] = r
        for name, n_in, n_out in res.names.get("etapas", []):
            if name in self.funnel:
                self.funnel[name] = [n_in, n_in, n_out]
        self.redraw()
        self.result_rows = res.rows
        from . import export
        base = os.path.join(os.path.dirname(os.path.abspath(self.path)) if self.path else os.getcwd(),
                            "rodadas_aeroopt")
        self.run_dir = export.write(res.rows, export.run_folder(base))
        n_eval = sum(len(r["history"]) for r in res.rows)
        gens = res.names.get("gerações", [])
        csv_txt = (f"<br>{len(gens)} gerações, {len(res.rows)} configurações de {res.names.get('combinações', '?')} "
                   f"combinações, {n_eval} pontos de projeto: CSV em {self.run_dir}")
        b = res.best
        self.bar.setValue(1000)
        if b:
            self.msg.setText(f"melhor: <b>{b['name']}</b> — nota {_fmt(b['nota'])}" +
                             ("" if b["valido"] else " (voo inválido)") + csv_txt)
            self.select(b["name"])
        else:
            self.msg.setText("nenhuma configuração chegou ao fim (veja a coluna situação)" + csv_txt)

    # ------------------------------------------------------------------ desenhar
    def redraw(self):
        _set_rows(self.stage_tab, [[s, a, b, c] for s, (a, b, c) in self.funnel.items()], editable=False)
        ok = [(i, m) for i, (m, good, _) in enumerate(self.points) if good and math.isfinite(m)]
        bad = [(i, m if math.isfinite(m) else 0.0) for i, (m, good, _) in enumerate(self.points) if not good]
        self.pts_ok.setData([p[0] for p in ok], [p[1] for p in ok])
        self.pts_bad.setData([p[0] for p in bad], [p[1] for p in bad])
        best, line = -math.inf, []
        for i, (m, good, _) in enumerate(self.points):
            if good and math.isfinite(m):
                best = max(best, m)
            line.append(best if math.isfinite(best) else np.nan)
        self.best_eval.setData(np.arange(len(line)), np.array(line, float), connect="finite")
        sc_rows = [self.rows[n] for n in self.order if n in self.rows and math.isfinite(self.rows[n]["nota"])]
        xs = {r["name"]: i for i, r in enumerate(sc_rows)}
        self.sc_ok.setData([xs[r["name"]] for r in sc_rows if r["valido"]], [r["nota"] for r in sc_rows if r["valido"]])
        self.sc_bad.setData([xs[r["name"]] for r in sc_rows if not r["valido"]],
                            [r["nota"] for r in sc_rows if not r["valido"]])
        best, line = -math.inf, []
        for r in sc_rows:
            best = max(best, r["nota"])
            line.append(best)
        self.best_score.setData(np.arange(len(line)), np.array(line, float))
        _fit_range(self.eval_plot, range(len(self.points)), [p[1] for p in ok + bad])
        _fit_range(self.score_plot, range(len(sc_rows)), [r["nota"] for r in sc_rows])
        self.draw_map()
        self.cfg_tab.setSortingEnabled(False)
        rows = sorted(self.rows.values(), key=lambda r: (r["alive"], r["valido"], np.nan_to_num(r["nota"], nan=-1e9)),
                      reverse=True)
        _set_rows(self.cfg_tab, [[r["name"], r.get("geração", ""), r["stage"], _fmt(r["mtow"]), _fmt(r["mtow6"]), _fmt(r["pv"]),
                                  _fmt(r["nota"]), ("válido" if r["valido"] else "voo inválido") if r["alive"] and
                                  math.isfinite(r["nota"]) else ("em andamento" if r["alive"] else r["why"])]
                                 for r in rows], editable=False)
        for i, r in enumerate(rows):
            if not r["alive"]:
                for j in range(self.cfg_tab.columnCount()):
                    self.cfg_tab.item(i, j).setForeground(QtCore.Qt.GlobalColor.darkRed)
        self.cfg_tab.setSortingEnabled(True)

    def _value(self, r: dict, key: str) -> float:
        m6 = r.get("mtow6", math.nan)
        mtow = m6 if math.isfinite(m6) else r.get("mtow", math.nan)
        cp = mtow - r.get("pv", math.nan)
        vals = dict(pv=r.get("pv", math.nan), cp=cp, mtow_f=mtow, ee=cp / r["pv"] if r.get("pv") else math.nan,
                    nota=r.get("nota", math.nan), b=r.get("b", math.nan), m_bat=r.get("m_bat", math.nan))
        return float(vals[key])

    def draw_map(self):
        self.map.clear()
        kx, ky = AXES[self.ax_x.currentText()], AXES[self.ax_y.currentText()]
        self.map.setLabel("bottom", self.ax_x.currentText())
        self.map.setLabel("left", self.ax_y.currentText())
        rows = [r for r in self.rows.values() if math.isfinite(self._value(r, kx)) and math.isfinite(self._value(r, ky))]
        if (kx, ky) == ("pv", "cp") and rows:        # linhas de EE constante: CP = EE · PV
            x1 = max(self._value(r, "pv") for r in rows) * 1.15
            for ee in EE_LINES:
                self.map.plot([0, x1], [0, ee * x1], pen=pg.mkPen("#b0b8c8", width=1, style=QtCore.Qt.PenStyle.DashLine))
                t = pg.TextItem(f"EE {ee:g}", color="#8090a8", anchor=(0, 1))
                t.setPos(x1, ee * x1)
                self.map.addItem(t)
        notas = [r["nota"] for r in rows if math.isfinite(r["nota"])]
        lo, hi = (min(notas), max(notas)) if notas else (0.0, 1.0)
        cmap = pg.colormap.get("viridis")
        spots = []
        for r in rows:
            n = r["nota"]
            if math.isfinite(n):
                c = cmap.map((n - lo) / (hi - lo) if hi > lo else 1.0, mode="qcolor")
                brush, pen = pg.mkBrush(c), pg.mkPen("#000" if r["valido"] else BAD_C, width=1.2 if r["valido"] else 2)
            else:
                brush, pen = pg.mkBrush(None), pg.mkPen("#999")
            size = 18 if r["name"] == self.selected else 12
            spots.append(dict(pos=(self._value(r, kx), self._value(r, ky)), brush=brush, pen=pen, size=size,
                              data=r["name"], symbol="o" if r["alive"] else "x"))
        _fit_range(self.map, [p["pos"][0] for p in spots], [p["pos"][1] for p in spots])
        sp = pg.ScatterPlotItem(spots=spots)
        sp.sigClicked.connect(lambda _it, pts, *_: pts and self.select(pts[0].data()))
        self.map.addItem(sp)
        for r in rows:
            if r["name"] == self.selected or (notas and r["nota"] == hi):
                t = pg.TextItem(r["name"], color="#1f2d3d", anchor=(0, 0))
                t.setPos(self._value(r, kx), self._value(r, ky))
                self.map.addItem(t)
        self.map_note.setText(f"cor: nota de {_fmt(lo)} (roxo) a {_fmt(hi)} (amarelo) · borda vermelha: voo inválido · "
                              "×: parou numa etapa" if notas else "")

    # ------------------------------------------------------------------ avião selecionado
    def select(self, name: str):
        r = self.rows.get(name)
        if r is None:
            return
        self.selected = name
        self.keep_b.setEnabled(True)
        self.aerosim_b.setEnabled(False)          # liga quando o avião estiver refeito (o 3D)
        self.draw_map()
        lines = [[sg.short(k), _fmt(v)] for k, v in r["values"].items()]
        lines += [["MTOW na pista (kg)", _fmt(r["mtow"])], ["MTOW 6GDL (kg)", _fmt(r["mtow6"])],
                  ["PV (kg)", _fmt(r["pv"])]]
        lines += [[f"entrada: {k}", _fmt(v)] for k, v in r.get("inputs", {}).items()]
        lines += [[f"fator: {k}", _fmt(v)] for k, v in r.get("termos", {}).items()]
        lines += [[("✔ " if ok else "✖ ") + txt, _fmt(x)] for txt, ok, x in r.get("validade", [])]
        lines += [["nota", _fmt(r["nota"])]] + ([["parou", r["why"]]] if not r["alive"] else [])
        _set_rows(self.sel_tab, lines, editable=False)
        if self.view is None or self.project is None:
            return
        pr, values = self.read_problem(), dict(r["values"])
        w = _Worker(lambda _w: sg.design(self.project, pr, values))
        w.done.connect(lambda d, n=name: self._show3d(n, d))
        th = QtCore.QThread(self)
        w.moveToThread(th)
        th.started.connect(w.run)
        for sig in (w.done, w.failed):
            sig.connect(th.quit)
        th.finished.connect(lambda: self._threads.remove((th, w)) if (th, w) in self._threads else None)
        self._threads.append((th, w))
        th.start()

    def _show3d(self, name: str, d: dict):
        if name == self.selected:
            self.selected_design = d
            self.aerosim_b.setEnabled(True)
            if self.view is not None:
                self.view.set_aircraft(d["ac"])

    def _export(self):
        rows = getattr(self, "result_rows", None) or list(self.rows.values())
        if not rows:
            self.msg.setText("nada para exportar: rode antes")
            return
        folder = QtWidgets.QFileDialog.getExistingDirectory(self, "Pasta para os CSV")
        if folder:
            from . import export
            export.write(rows, folder)
            self.msg.setText(f"gravado: {folder}/avaliacoes.csv e configuracoes.csv")

    def open_aerosim(self):
        """o avião selecionado numa janela do aerosim (todas as abas). O projeto vai para uma pasta própria da
        rodada, então a sprint do usuário não é tocada"""
        r, d = self.rows.get(self.selected or ""), getattr(self, "selected_design", None)
        if r is None or d is None:
            return
        from aerosim.gui.main_window import MainWindow
        from aerosim.gui.state import AppState
        from aerosim.manager import SimulationManager
        p = copy.deepcopy(self.project)
        sg.apply_values(p, r["values"])
        ac = copy.deepcopy(d["ac"])
        ac.name = r["name"]
        p.fleet, p.current = [ac], 0
        base = getattr(self, "run_dir", None) or os.path.join(os.getcwd(), "rodadas_aeroopt")
        folder = os.path.join(base, "aerosim_" + "".join(ch if ch.isalnum() else "_" for ch in r["name"])[:60])
        os.makedirs(folder, exist_ok=True)
        st = AppState(SimulationManager(), ac, design_dir=folder)
        st.open_design(p, folder)
        win = MainWindow(st)
        win.setWindowTitle(f"aerosim — {r['name']} (do aeroopt)")
        win.show()
        self._aerosim_windows = getattr(self, "_aerosim_windows", []) + [win]
        return win

    def _keep(self):
        r = self.rows.get(self.selected or "")
        if r is None:
            return
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Gravar projeto", "", "projeto (*.json)")
        if path:
            p = copy.deepcopy(self.project)
            sg.apply_values(p, r["values"])
            p.save(path)
            self.msg.setText(f"gravado: {path} (os valores estão nos rascunhos das etapas)")


def example_project():
    """um avião pequeno, perto da classe Micro (pista de 8 m, envergadura até 1,8 m), com asa, conjunto e motores
    guardados, para ver a janela funcionando"""
    from aerosim.design.project import DesignProject
    p = DesignProject()
    p.wing_draft.area, p.wing_draft.span, p.wing_draft.alpha_cruise = 0.5, 1.75, 3.0
    p.requirements.takeoff_run, p.requirements.V_stall_max, p.requirements.mass = 8.0, 14.0, 2.0
    r = p.rules                                          # estrutura leve, de avião pequeno
    r.wing_density, r.tail_density, r.fuselage_density, r.boom_density = 0.45, 0.3, 0.25, 0.06
    r.systems_mass, r.gear_mass, r.main_gear_aft = 0.12, 0.10, 0.02
    r.fuselage_width, r.fuselage_height = 0.10, 0.14
    pd = p.power_draft
    pd.motor, pd.propeller, pd.battery, pd.layout, pd.wing_motors = ("Genérico 900Kv", "Genérica 13x6.5",
                                                                     "LiPo 4S 4000", "tratora no nariz", 0)
    p.tail_draft.arm, p.tail_draft.VH = 0.6, 0.7
    w = p.keep_wing()
    p.tail_draft.wing = w.name
    pd.set = p.keep_set().name
    pr = aeroopt.from_project(p, "exemplo: avião pequeno, Micro 2026")
    pr.scoring = "sae_br_2026_micro"
    for v in pr.variables:
        v.free = v.key in ("wing.span", "wing.area", "power.propeller")
        if v.key == "wing.span":
            v.lo, v.hi = 1.5, 1.85
        if v.key == "wing.area":
            v.lo, v.hi = 0.4, 0.6
        if v.key == "power.propeller":
            v.options = ["Genérica 11x7", "Genérica 13x6.5", "APC 15x8E"]
    pr.params["categorias"] = ["asa alta", "asa baixa", "biplano", "asa voadora", "cauda em V"]
    return p, pr


def main(argv=None) -> int:
    import sys
    argv = sys.argv[1:] if argv is None else argv
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv[:1])
    from aerosim.design.project import DesignProject
    project, problem, path = None, None, ""
    if "--exemplo" in argv:
        project, problem = example_project()
    for a in argv:
        if a.endswith(".opt.json"):
            problem = aeroopt.load(a)
        elif a.endswith(".json"):
            project, path = DesignProject.load(a), a
    win = AeroOptWindow(project, problem, path)
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
