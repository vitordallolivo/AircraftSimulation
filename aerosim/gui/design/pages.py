"""As etapas da sprint na GUI: cada uma edita um rascunho, mostra na hora o que vai ser feito (3D da peça,
gráficos, diagnóstico) e guarda candidatos com nome para a etapa seguinte.

    AirfoilPage  (Aerodinâmica → Perfil)       perfis candidatos e a polar de cada um
    WingPage     (Aerodinâmica → Asa)          a asa a partir do perfil escolhido
    TailPage     (Estabilidade → Empenagem)    cauda, tubo e comandos para a asa guardada
    PowerPage    (Desempenho → Motores)        motores, massas, trem → avião inteiro para a Montagem

As contas estão em `aerosim.design` (a GUI só mostra); o projeto fica em `state.design`.
"""
from __future__ import annotations

import copy
import math
import os
import traceback

from PyQt6 import QtCore, QtWidgets

from aerosim.design import airfoils as afm
from aerosim.design import registry as rg
from aerosim.design import results as R
from aerosim.design import wing as wg
from aerosim.model.aircraft import Aircraft

from ..state import ROOT, AppState
from ..widgets.checks_panel import ChecksPanel
from ..widgets.param_slider import HELP_MARK, DataclassForm
from ..widgets.plots import LivePlots

TAIL_AIRFOILS = ("NACA 0012", "NACA 0010", "NACA 0009", "NACA 0008")


def _only_wing(surfaces, boom=None) -> Aircraft:
    """um 'avião' só com as peças desta etapa (para o 3D)"""
    ac = Aircraft(name="prévia", surfaces=copy.deepcopy(surfaces))
    ac.fuselage.enabled = False
    ac.gear.layout = "custom"
    ac.propulsion = []
    ac.tanks = []
    ac.payload.enabled = False
    if boom is not None:
        ac.boom = copy.deepcopy(boom)
    return ac


def _last_values(state) -> dict:
    """as grandezas calculadas pela última etapa que rodou (asa, avião montado)"""
    return getattr(state, "design_values", {})


class ConstraintsTable(QtWidgets.QWidget):
    """restrições: ativa | grandeza | operador | valor | unidade | último calculado | situação"""
    COLS = ["ativa", "grandeza", "op.", "valor", "unid.", "calculado", "situação"]

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        v = QtWidgets.QVBoxLayout(self)
        note = QtWidgets.QLabel("Restrições de projeto: ligue/desligue sem perder o valor. As etapas conferem as "
                                "ativas no diagnóstico; o estudo marca como inviável o ponto que não cumpre. "
                                "'calculado' é o valor da última etapa que rodou.")
        note.setWordWrap(True)
        note.setStyleSheet("color:#555")
        v.addWidget(note)
        self.table = QtWidgets.QTableWidget(0, len(self.COLS))
        self.table.setHorizontalHeaderLabels(self.COLS)
        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        v.addWidget(self.table)
        h = QtWidgets.QHBoxLayout()
        for txt, fn in (("+ restrição", self.add), ("− restrição", self.remove)):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            h.addWidget(b)
        v.addLayout(h)
        self.fill()

    @property
    def items(self) -> list:
        return self.state.design.requirements.constraints

    def edited(self):
        self.state.design_edited("requisitos")
        self.fill()

    def fill(self):
        t = self.table
        vals = _last_values(self.state)
        keys = list(rg.QUANTITIES)
        t.setRowCount(len(self.items))
        for r, c in enumerate(self.items):
            ck = QtWidgets.QCheckBox()
            ck.setChecked(c.active)
            ck.toggled.connect(lambda on, c=c: (setattr(c, "active", on), self.edited()))
            t.setCellWidget(r, 0, ck)
            q = QtWidgets.QComboBox()
            q.addItems([rg.QUANTITIES[k].label for k in keys])
            q.setCurrentIndex(keys.index(c.key) if c.key in keys else 0)
            q.setToolTip(c.quantity.help)
            q.currentIndexChanged.connect(lambda i, c=c: (setattr(c, "key", keys[i]), self.edited()))
            t.setCellWidget(r, 1, q)
            op = QtWidgets.QComboBox()
            op.addItems(rg.OPS)
            op.setCurrentText(c.op)
            op.currentTextChanged.connect(lambda s, c=c: (setattr(c, "op", s), self.edited()))
            t.setCellWidget(r, 2, op)
            sp = QtWidgets.QDoubleSpinBox()
            sp.setRange(-1e6, 1e6)
            sp.setDecimals(3)
            sp.setValue(c.value)
            sp.setKeyboardTracking(False)
            sp.valueChanged.connect(lambda x, c=c: (setattr(c, "value", x), self.edited()))
            t.setCellWidget(r, 3, sp)
            t.setItem(r, 4, QtWidgets.QTableWidgetItem(c.quantity.unit))
            x = vals.get(c.key)
            t.setItem(r, 5, QtWidgets.QTableWidgetItem(rg.fmt(x) if x is not None else "—"))
            st = "desligada" if not c.active else ("—" if x is None else ("✔ cumpre" if c.holds(x) else "✖ não cumpre"))
            it = QtWidgets.QTableWidgetItem(st)
            if st.startswith("✖"):
                it.setForeground(QtCore.Qt.GlobalColor.red)
            t.setItem(r, 6, it)
            for col in (4, 5, 6):
                t.item(r, col).setFlags(QtCore.Qt.ItemFlag.ItemIsEnabled)

    def add(self):
        self.items.append(rg.Constraint("S", "≤", 1.0))
        self.edited()

    def remove(self):
        r = self.table.currentRow()
        if 0 <= r < len(self.items):
            del self.items[r]
            self.edited()


class VariablesTable(QtWidgets.QWidget):
    """variáveis: fixo (vale o valor do rascunho), variável (faixa para o otimizador) ou calculado"""
    COLS = ["entrada", "modo", "valor (fixo)", "mín.", "máx.", "opções (listas)"]

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        v = QtWidgets.QVBoxLayout(self)
        note = QtWidgets.QLabel("Entradas de projeto: fixo = o valor do rascunho da etapa; variável = o otimizador "
                                "procura entre mín. e máx. (listas: entre as opções); calculado = sai das contas "
                                "(ex.: a massa, que o ponto de projeto acerta). PV e MTOW são saídas.")
        note.setWordWrap(True)
        note.setStyleSheet("color:#555")
        v.addWidget(note)
        self.table = QtWidgets.QTableWidget(0, len(self.COLS))
        self.table.setHorizontalHeaderLabels(self.COLS)
        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(5, QtWidgets.QHeaderView.ResizeMode.Stretch)
        v.addWidget(self.table)
        self.fill()

    def edited(self):
        self.state.design_edited("variaveis")

    def fill(self):
        d = self.state.design
        known = {v.key for v in d.variables}
        d.variables += [rg.Variable(k, "fixo", i.lo, i.hi) for k, i in rg.INPUTS.items() if k not in known]
        t = self.table
        t.setRowCount(len(d.variables))
        for r, var in enumerate(d.variables):
            inp = var.input
            lst = inp.unit == "lista"
            it = QtWidgets.QTableWidgetItem(inp.label + ("" if lst or not inp.unit else f" ({inp.unit})"))
            it.setFlags(QtCore.Qt.ItemFlag.ItemIsEnabled)
            t.setItem(r, 0, it)
            m = QtWidgets.QComboBox()
            m.addItems(rg.MODES)
            m.setCurrentText(var.mode)
            m.currentTextChanged.connect(lambda s, var=var: (setattr(var, "mode", s), self.edited()))
            t.setCellWidget(r, 1, m)
            try:
                cur = rg.get_input(d, var.key)
            except AttributeError:
                cur = ""
            if lst or isinstance(cur, str):
                val = QtWidgets.QLineEdit(str(cur))
                val.editingFinished.connect(lambda var=var, w=val: (rg.set_input(d, var.key, w.text()), self.edited()))
            else:
                val = QtWidgets.QDoubleSpinBox()
                val.setRange(-1e6, 1e6)
                val.setDecimals(3)
                val.setValue(float(cur))
                val.setKeyboardTracking(False)
                val.valueChanged.connect(lambda x, var=var: (rg.set_input(d, var.key, x), self.edited()))
            t.setCellWidget(r, 2, val)
            for col, attr in ((3, "lo"), (4, "hi")):
                sp = QtWidgets.QDoubleSpinBox()
                sp.setRange(-1e6, 1e6)
                sp.setDecimals(3)
                sp.setValue(getattr(var, attr))
                sp.setEnabled(not lst)
                sp.setKeyboardTracking(False)
                sp.valueChanged.connect(lambda x, var=var, a=attr: (setattr(var, a, x), self.edited()))
                t.setCellWidget(r, col, sp)
            op = QtWidgets.QLineEdit(", ".join(var.options))
            op.setEnabled(lst)
            op.setPlaceholderText("nomes separados por vírgula" if lst else "")
            op.editingFinished.connect(lambda var=var, w=op: (setattr(var, "options", [s.strip() for s in
                                                                                  w.text().split(",") if s.strip()]),
                                                              self.edited()))
            t.setCellWidget(r, 5, op)


class RequirementsDialog(QtWidgets.QDialog):
    """condições, restrições, variáveis e regras do projeto (editados no lugar; cada mudança refaz as etapas)"""

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Condições, restrições e variáveis de projeto")
        self.resize(900, 600)
        v = QtWidgets.QVBoxLayout(self)
        self.tabs = tabs = QtWidgets.QTabWidget()

        def form(obj):
            sc = QtWidgets.QScrollArea()
            sc.setWidgetResizable(True)
            f = DataclassForm(obj)
            f.changed.connect(lambda *_: state.design_edited("requisitos"))
            sc.setWidget(f)
            return sc
        tabs.addTab(form(state.design.requirements), "Condições")
        self.constraints = ConstraintsTable(state)
        tabs.addTab(self.constraints, "Restrições")
        self.variables = VariablesTable(state)
        tabs.addTab(self.variables, "Variáveis")
        tabs.addTab(form(state.design.rules), "Regras de projeto")
        v.addWidget(tabs)
        b = QtWidgets.QPushButton("Fechar")
        b.clicked.connect(self.accept)
        v.addWidget(b)


class ReqBar(QtWidgets.QWidget):
    """uma linha com os requisitos (sempre à vista) e o botão para editar"""

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        self.text = QtWidgets.QLabel()
        self.text.setWordWrap(True)
        self.text.setStyleSheet("color:#334; font-size:11px; background:#eef3fa; padding:3px; border-radius:3px")
        b = QtWidgets.QPushButton("Condições e restrições…")
        b.setToolTip("condições (massa de partida, velocidade, AD, pista), restrições ligáveis (≤, ≥, =), variáveis de "
                     "projeto (fixo, variável, calculado) e regras (massas, fuselagem, trem)")
        b.clicked.connect(lambda: RequirementsDialog(state, self).exec())
        h.addWidget(self.text, 1)
        h.addWidget(b)
        state.designChanged.connect(lambda *_: self.refresh())
        self.refresh()

    def refresh(self):
        self.text.setText(self.state.design.requirements.summary())


class StagePage(QtWidgets.QWidget):
    """esquerda: requisitos, escolhas e o rascunho; guardados embaixo. Direita: a peça em 3D, gráficos e
    diagnóstico, refeitos a cada mudança"""
    title = ""
    help = ""
    keep_label = "Guardar"
    show_3d = True
    columns = 2

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        self.form: DataclassForm | None = None
        self._plots_sig = None
        self._dirty = True
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.setHandleWidth(8)
        split.setChildrenCollapsible(False)
        QtWidgets.QHBoxLayout(self).addWidget(split)
        # ---- esquerda
        left_in = QtWidgets.QWidget()
        self.left = QtWidgets.QVBoxLayout(left_in)
        self.left.addWidget(ReqBar(state))
        t = QtWidgets.QLabel(f"<b>{self.title}</b>" + (HELP_MARK if self.help else ""))
        t.setToolTip(self.help)
        self.left.addWidget(t)
        self.top = QtWidgets.QVBoxLayout()
        self.left.addLayout(self.top)
        self.form_box = QtWidgets.QVBoxLayout()
        self.left.addLayout(self.form_box)
        row = QtWidgets.QHBoxLayout()
        self.keep_b = QtWidgets.QPushButton(self.keep_label)
        self.keep_b.clicked.connect(self._keep)
        row.addWidget(self.keep_b)
        self.left.addLayout(row)
        self.actions = row
        self.kept_box = QtWidgets.QGroupBox("Guardados")
        kv = QtWidgets.QVBoxLayout(self.kept_box)
        self.kept = QtWidgets.QListWidget()
        self.kept.setMaximumHeight(110)
        kv.addWidget(self.kept)
        kr = QtWidgets.QHBoxLayout()
        self.load_b = QtWidgets.QPushButton("Carregar no rascunho")
        self.del_b = QtWidgets.QPushButton("Apagar")
        self.load_b.clicked.connect(self._load_kept)
        self.del_b.clicked.connect(self._del_kept)
        kr.addWidget(self.load_b)
        kr.addWidget(self.del_b)
        kv.addLayout(kr)
        self.kept_actions = kr
        self.left.addWidget(self.kept_box)
        self.left.addStretch(1)
        ls = QtWidgets.QScrollArea()
        ls.setWidgetResizable(True)
        ls.setWidget(left_in)
        ls.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        split.addWidget(ls)
        # ---- direita
        rs = QtWidgets.QScrollArea()
        rs.setWidgetResizable(True)
        rs.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        right_in = QtWidgets.QWidget()
        self.right = QtWidgets.QVBoxLayout(right_in)
        self.view = None
        if self.show_3d:
            from ..widgets.view3d import AircraftView
            self.view = AircraftView()
            self.view.move_mode = False
            self.view.setMinimumHeight(250)
            self.view.setMaximumHeight(300)
            self.right.addWidget(self.view)
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        self.right.addWidget(self.msg)
        self.plots = LivePlots([])
        self.right.addWidget(self.plots)
        self.checks = ChecksPanel()
        self.right.addWidget(self.checks)
        self.right.addStretch(1)
        rs.setWidget(right_in)
        split.addWidget(rs)
        split.setSizes([380, 980])
        self._timer = QtCore.QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(300)
        self._timer.timeout.connect(self.recompute)
        state.designChanged.connect(self._on_design)
        state.changed.connect(lambda r: self._on_design("catalogo") if r == "catalog" else None)

    # ------------------------------------------------------------------ o que cada etapa define
    def draft(self):
        raise NotImplementedError

    def set_draft(self, params) -> None:
        raise NotImplementedError

    def choices(self) -> dict:
        return {}

    def editable(self) -> tuple:
        return ()

    def kept_items(self) -> list:
        return []

    def compute(self):
        """→ (gráficos, resultado, aeronave do 3D ou None, marcadores)"""
        raise NotImplementedError

    def keep(self):
        raise NotImplementedError

    # ------------------------------------------------------------------ comum
    def build(self) -> None:
        self.sanitize()
        if self.form is not None:
            self.form_box.removeWidget(self.form)
            self.form.hide()
            self.form.setParent(None)
            self.form.deleteLater()
        self.form = DataclassForm(self.draft(), choices=self.choices(), editable=self.editable())
        self.form.changed.connect(self._edited)
        self.form_box.addWidget(self.form)
        self.fill_kept()

    def sanitize(self) -> None:
        """escolhas que não existem mais viram a primeira disponível"""
        d = self.draft()
        for k, opts in self.choices().items():
            if opts and k not in self.editable() and getattr(d, k) not in opts:
                setattr(d, k, opts[0] if k not in ("set", "wing") else opts[-1])

    def fill_kept(self) -> None:
        cur = self.kept.currentRow()
        self.kept.clear()
        for it in self.kept_items():
            self.kept.addItem(it.name)
        if 0 <= cur < self.kept.count():
            self.kept.setCurrentRow(cur)
        self.kept_box.setTitle(f"Guardados ({self.kept.count()})")

    def _edited(self, *_):
        self.state.design_edited(self.title)
        self._timer.start()

    def _on_design(self, stage):
        if stage == self.title:
            return
        self._dirty = True
        if self.isVisible():
            self.build()
            self._timer.start()

    def showEvent(self, e):
        super().showEvent(e)
        if self._dirty or self.form is None:
            self.build()
            self._timer.start(0)

    def recompute(self) -> None:
        self._dirty = False
        try:
            out = self.compute()
        except Exception as ex:
            self.msg.setText(f"<span style='color:#b00'>{type(ex).__name__}: {ex}</span>")
            traceback.print_exc()
            return
        if out is None:
            return
        specs, res, ac, markers = out
        self.msg.setText("")
        sig = tuple((s.key, s.title) for s in specs)
        if sig != self._plots_sig:
            new = LivePlots(specs, columns=self.columns, row_height=300)
            self.right.replaceWidget(self.plots, new)
            self.plots.hide()
            self.plots.setParent(None)
            self.plots.deleteLater()
            self.plots = new
            self._plots_sig = sig
        self.plots.show_result(res)
        self.checks.show_checks(res.checks)
        self.checks.show_summary(res.summary)
        if self.view is not None:
            self.view.set_aircraft(ac)
            self.view.clear_markers()
            if markers:
                self.view.set_markers(**markers)
        self.result = res

    def _keep(self):
        name = self.keep()
        if name:
            self.state.design_edited("guardou")
            self.build()
            self.recompute()
            self.msg.setText(f"guardado: <b>{name}</b>")

    def _sel(self):
        r = self.kept.currentRow()
        items = self.kept_items()
        return items[r] if 0 <= r < len(items) else None

    def _load_kept(self):
        it = self._sel()
        if it is not None:
            self.set_draft(copy.deepcopy(it.params))
            self.build()
            self._edited()

    def _del_kept(self):
        it = self._sel()
        if it is not None:
            self.kept_items().remove(it)
            self.state.design_edited("apagou")
            self.build()


# ====================================================================== Perfil
class AirfoilPage(StagePage):
    title = "Perfil"
    help = ("Perfis candidatos e a polar 2D de cada um no Re do cruzeiro. O perfil pode vir de um código NACA, "
            "de um .dat, só de parâmetros (sem contorno) ou da polar do XFLR5/XFOIL. 'Usar na asa' leva o "
            "perfil selecionado para a etapa Asa.")
    keep_label = "Usar na asa →"
    show_3d = False

    def __init__(self, state, parent=None):
        super().__init__(state, parent)
        self.kept_box.hide()
        self.list = QtWidgets.QListWidget()
        self.list.setMaximumHeight(120)
        self.list.currentRowChanged.connect(lambda *_: self.build_editor())
        self.top.addWidget(QtWidgets.QLabel("Candidatos (todos entram nos gráficos):"))
        self.top.addWidget(self.list)
        g = QtWidgets.QGridLayout()
        for i, (txt, fn, tip) in enumerate((
                ("+ NACA…", self._add_naca, "código de 4 dígitos"),
                ("+ .dat…", self._add_dat, "contorno Selig ou Lednicer"),
                ("+ só parâmetros", self._add_param, "sem contorno: a1, α_L0, c_l,max, c_d0, c_m"),
                ("+ polar XFLR5…", self._add_polar, "polar exportada (texto ou CSV); vai para o perfil selecionado"),
                ("Remover", self._remove, ""))):
            b = QtWidgets.QPushButton(txt)
            b.setToolTip(tip)
            b.clicked.connect(fn)
            g.addWidget(b, i // 2, i % 2)
        self.top.addLayout(g)
        self.re_label = QtWidgets.QLabel()
        self.re_label.setStyleSheet("color:#555")
        self.re_label.setWordWrap(True)
        self.top.addWidget(self.re_label)

    def entries(self):
        return self.state.design.airfoils

    def current(self):
        r = self.list.currentRow()
        e = self.entries()
        return e[r] if 0 <= r < len(e) else None

    def draft(self):
        return self.current()

    def build(self) -> None:
        cur = self.list.currentRow()
        self.list.blockSignals(True)
        self.list.clear()
        for e in self.entries():
            self.list.addItem(f"{e.name}   ({afm.kind(e.airfoil)}, polar: {e.source})")
        self.list.setCurrentRow(min(max(cur, 0), self.list.count() - 1))
        self.list.blockSignals(False)
        self.build_editor()

    def build_editor(self):
        if self.form is not None:
            self.form_box.removeWidget(self.form)
            self.form.hide()
            self.form.setParent(None)
            self.form.deleteLater()
            self.form = None
        e = self.current()
        if e is None:
            return
        self.form = DataclassForm(e, exclude=("polar_file",), choices={"source": tuple(afm.sources(e))})
        box = self.form.widgets.get("airfoil")
        if isinstance(box, QtWidgets.QGroupBox) and e.source != "modelo":
            box.setTitle("perfil — os números abaixo só valem na polar 'modelo'; com "
                         f"{e.source} eles saem ajustados da polar (veja os resultados)")
        self.form.changed.connect(self._edited)
        self.form_box.addWidget(self.form)

    def _edited(self, *_):
        super()._edited()
        r = self.list.currentRow()
        e = self.current()
        if e is not None and r >= 0:
            self.list.item(r).setText(f"{e.name}   ({afm.kind(e.airfoil)}, polar: {e.source})")

    def reynolds(self) -> float:
        d = self.state.design
        pf = wg.planform(wg.build_wing(d.wing_draft, afm.Airfoil()))
        return d.requirements.reynolds(pf["mac"])

    def compute(self):
        Re = self.reynolds()
        self.re_label.setText(f"Re = {Re:,.0f}".replace(",", " ") + " (cruzeiro, corda média da asa)")
        specs, res = R.airfoil_stage(self.entries(), Re)
        return specs, res, None, None

    def keep(self):
        e = self.current()
        if e is None:
            return None
        self.state.design.wing_draft.airfoil = e.name
        tabs = self.parentWidget()
        while tabs is not None and not isinstance(tabs, QtWidgets.QTabWidget):
            tabs = tabs.parentWidget()
        if tabs is not None and tabs.count() > 1:
            tabs.setCurrentIndex(min(tabs.indexOf(self) + 1, tabs.count() - 1))
        return e.name

    def _add(self, e):
        names = [x.name for x in self.entries()]
        if e.name in names:
            QtWidgets.QMessageBox.information(self, "Perfil", f"'{e.name}' já está na lista.")
            return
        self.entries().append(e)
        self.state.design_edited("perfis")
        self.build()
        self.list.setCurrentRow(len(self.entries()) - 1)
        self._timer.start()

    def _add_naca(self):
        code, ok = QtWidgets.QInputDialog.getText(self, "Perfil NACA", "Código de 4 dígitos:", text="4412")
        if ok and len("".join(c for c in code if c.isdigit())) == 4:
            self._add(afm.entry(afm.from_naca(code)))

    def _add_dat(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Perfil (.dat)", os.path.join(ROOT, "data", "airfoils"),
                                                        "Perfil (*.dat *.txt)")
        if path:
            try:
                self._add(afm.entry(afm.from_dat(path)))
            except Exception as ex:
                QtWidgets.QMessageBox.critical(self, "Perfil", str(ex))

    def _add_param(self):
        n = len(self.entries()) + 1
        self._add(afm.AirfoilEntry(afm.Airfoil(name=f"perfil {n}", alpha0=-3.0, cm_ac=-0.08, cl_max=1.5)))

    def _add_polar(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Polar do XFLR5/XFOIL", "", "Polar (*.txt *.csv *.dat *.pol)")
        if not path:
            return
        try:
            p = afm.read_polar_file(path)
        except Exception as ex:
            QtWidgets.QMessageBox.critical(self, "Polar", str(ex))
            return
        e = self.current()
        if e is None:
            e = afm.AirfoilEntry(afm.Airfoil(name=os.path.splitext(os.path.basename(path))[0]))
            self.entries().append(e)
        e.polar_file = path
        e.source = "arquivo"
        self.state.design_edited("perfis")
        self.build()
        self._timer.start()
        self.msg.setText(f"polar lida: {len(p['alpha'])} pontos, Re {p['Re']:.3g}")

    def _remove(self):
        e = self.current()
        if e is not None:
            self.entries().remove(e)
            self.state.design_edited("perfis")
            self.build()
            self._timer.start()


# ====================================================================== Asa
class WingPage(StagePage):
    title = "Asa"
    help = ("A asa a partir do perfil escolhido: forma em planta, linha sustentadora, onde o estol começa, polar e "
            "L/D. A incidência sai do ângulo de cruzeiro. Guarde as asas que quiser comparar: a etapa Empenagem "
            "parte de uma delas.")
    keep_label = "Guardar asa"

    def draft(self):
        return self.state.design.wing_draft

    def set_draft(self, params):
        self.state.design.wing_draft = params

    def choices(self):
        return {"airfoil": tuple(a.name for a in self.state.design.airfoils)}

    def kept_items(self):
        return self.state.design.wings

    def compute(self):
        d = self.state.design
        cand = d.draft_wing()
        others = [w for w in d.wings if w.name != cand.name]
        specs, res, r = R.wing_stage(cand, d.requirements, d.rules, others)
        self.state.design_values = {**_last_values(self.state), **rg.wing_values(r)}
        return specs, res, _only_wing([r["surface"]]), dict(np_x=r["planform"]["x_ac"])

    def keep(self):
        d = self.state.design
        c = d.keep_wing()
        d.tail_draft.wing = c.name
        return c.name


# ====================================================================== Empenagem
class TailPage(StagePage):
    title = "Empenagem e comandos"
    help = ("As superfícies que acompanham a asa guardada: cauda (convencional, em V ou sem cauda), tubo, "
            "profundor, leme e aileron, por volume de cauda. Põe o CG na margem pedida e diz a faixa de CG, a "
            "incidência da EH e se os comandos dão conta. Guarde conjuntos para a etapa Motores.")
    keep_label = "Guardar conjunto"

    def draft(self):
        return self.state.design.tail_draft

    def set_draft(self, params):
        self.state.design.tail_draft = params

    def choices(self):
        d = self.state.design
        return {"wing": tuple(w.name for w in d.wings),
                "tail_airfoil": tuple(dict.fromkeys(TAIL_AIRFOILS + tuple(a.name for a in d.airfoils))),
                "vtail_airfoil": tuple(dict.fromkeys(TAIL_AIRFOILS + tuple(a.name for a in d.airfoils)))}

    def editable(self):
        return ("tail_airfoil", "vtail_airfoil")

    def kept_items(self):
        return self.state.design.sets

    def compute(self):
        d = self.state.design
        cand = d.draft_set()
        if cand is None:
            self.msg.setText("Guarde uma asa primeiro (Aerodinâmica → Asa → Guardar asa).")
            return None
        specs, res, r = R.set_stage(cand, d.requirements, d.rules, d.airfoil_map())
        ac = r["set"]
        return specs, res, _only_wing(ac.surfaces, ac.boom), dict(cg=[r["x_cg"], 0.0, 0.0], np_x=r["x_np"])

    def keep(self):
        d = self.state.design
        c = d.keep_set()
        if c is None:
            return None
        d.power_draft.set = c.name
        return c.name


# ====================================================================== Motores e montagem
class PowerPage(StagePage):
    title = "Motores e montagem"
    help = ("Onde ficam os motores, e com isso a bateria (posta onde o CG cai na margem), a carga paga (no CG), a "
            "fuselagem e o trem. Mostra o desempenho rápido do avião montado e a massa máxima que a pista permite. "
            "'Mandar para a Montagem' abre o avião como mais um avião aberto e o salva em 'meus aviões'.")
    keep_label = "Guardar avião"

    def __init__(self, state, parent=None):
        super().__init__(state, parent)
        self.send_b = QtWidgets.QPushButton("Mandar para a Montagem →")
        self.send_b.setToolTip("abre o avião do rascunho (ou o guardado selecionado) como novo avião e salva em "
                               "'meus aviões'")
        self.send_b.clicked.connect(self.send)
        self.actions.addWidget(self.send_b)
        self.ac = None
        # distribuição de massa (PV e CP), logo abaixo do 3D
        self.mass_title = QtWidgets.QLabel("<b>Distribuição de massa</b>" + HELP_MARK)
        self.mass_title.setToolTip("PV: peso vazio (estrutura, motores, bateria, sistemas). CP: carga paga = lastro + "
                                   "líquido + LAPES (digite quanto de cada à esquerda), tudo no CG. MTOW pela pista − PV "
                                   "= a carga paga que dá para levar")
        self.mass = QtWidgets.QTableWidget(0, 5)
        self.mass.setHorizontalHeaderLabels(["grupo", "item", "massa (kg)", "x (m)", "% do total"])
        self.mass.verticalHeader().setVisible(False)
        self.mass.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.mass.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        hh = self.mass.horizontalHeader()
        hh.setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.right.insertWidget(1, self.mass_title)
        self.right.insertWidget(2, self.mass)

    def fill_mass(self, asm: dict, pf: dict) -> None:
        from PyQt6 import QtGui
        M = asm["mass"]
        rows = [(g, n, m, f"{x:.3f}", f"{100 * m / M:.1f}") for g, n, m, x in asm["mass_table"]]
        rows += [("PV", "peso vazio", asm["empty"], "", f"{100 * asm['empty'] / M:.1f}"),
                 ("CP", "carga paga", asm["payload"], "", f"{100 * asm['payload'] / M:.1f}"),
                 ("", "total", M, f"{asm['x_cg_target']:.3f} (CG)", "100")]
        mt = pf.get("mtow_runway", float("nan"))
        if mt == mt:
            rows.append(("", "MTOW pela pista → CP possível = MTOW − PV", mt, "", f"CP {mt - asm['empty']:.2f} kg"))
        self.mass.setRowCount(len(rows))
        bold = QtGui.QFont()
        bold.setBold(True)
        color = {"PV": "#eef3fa", "CP": "#eaf7ee"}
        for r, row in enumerate(rows):
            total = row[1] in ("peso vazio", "carga paga", "total") or row[1].startswith("MTOW")
            for c, v in enumerate(row):
                it = QtWidgets.QTableWidgetItem(f"{v:.3f}" if isinstance(v, float) else str(v))
                if row[0] in color:
                    it.setBackground(QtGui.QColor(color[row[0]]))
                if total:
                    it.setFont(bold)
                self.mass.setItem(r, c, it)
        self.mass.resizeRowsToContents()
        self.mass.setFixedHeight(self.mass.horizontalHeader().height() + 4 +
                                 sum(self.mass.rowHeight(i) for i in range(len(rows))))

    def draft(self):
        return self.state.design.power_draft

    def set_draft(self, params):
        self.state.design.power_draft = params

    def choices(self):
        cat = self.state.catalog
        return {"set": tuple(s.name for s in self.state.design.sets),
                "motor": tuple(m.name for m in cat.motors), "propeller": tuple(p.name for p in cat.propellers),
                "battery": tuple(b.name for b in cat.batteries),
                "thrust_set": tuple(t.name for t in cat.thrust_sets) or ("",)}

    def kept_items(self):
        return self.state.design.aircraft

    def compute(self):
        d = self.state.design
        cand = d.draft_aircraft()
        if cand is None:
            self.msg.setText("Guarde um conjunto primeiro (Estabilidade → Empenagem e comandos → Guardar conjunto).")
            return None
        specs, res, ac, asm, pf = R.aircraft_stage(cand, d.requirements, d.rules, self.state.catalog,
                                                   self.state.manager.backend, d.airfoil_map())
        self.ac = ac
        self.state.design_values = {**_last_values(self.state), **rg.aircraft_values(ac, asm, pf, cand.params)}
        self.fill_mass(asm, pf)
        return specs, res, ac, dict(cg=[asm["x_cg_target"], 0.0, 0.0])

    def keep(self):
        c = self.state.design.keep_aircraft()
        return None if c is None else c.name

    def send(self):
        from aerosim.design import power as pw
        d = self.state.design
        it = self._sel() if self.kept.hasFocus() or self.kept.currentRow() >= 0 else None
        cand = it if it is not None else d.draft_aircraft()
        if cand is None:
            return
        ac, _ = pw.assemble(cand, d.requirements, d.rules, self.state.catalog, d.airfoil_map())
        send_to_assembly(self.state, ac, self)


def send_to_assembly(state: AppState, ac, widget) -> bool:
    """o avião vira mais um avião aberto (Montagem) e fica salvo em 'meus aviões' (nome livre: acrescenta (2)...)
    — só se voar: antes, a decolagem 6GDL acha e grava no avião o acionamento do profundor; se não decolar,
    nada é salvo nem aberto"""
    from aerosim.design.flight import tune_takeoff
    QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.CursorShape.WaitCursor)
    try:
        ok, why = tune_takeoff(ac, state.manager.backend)
    finally:
        QtWidgets.QApplication.restoreOverrideCursor()
    if not ok:
        QtWidgets.QMessageBox.warning(widget, "Não foi para a Montagem", f"'{ac.name}' {why}. Não foi salvo.")
        return False
    if hasattr(widget, "msg"):
        widget.msg.setText(f"{ac.name}: {why}")
    st = state.projects
    name = ac.name
    k = 2
    while st.exists(name):
        name = f"{ac.name} ({k})"
        k += 1
    ac.name = name
    path = None
    try:
        path = st.save(ac, name).path
    except Exception as ex:
        QtWidgets.QMessageBox.warning(widget, "Salvar", f"não salvei em 'meus aviões': {ex}")
    state.add(ac, path)
    win = widget.window()
    if hasattr(win, "show_assembly"):
        win.show_assembly()
    return True


# ====================================================================== Estudo e ponto de projeto
class _StudyWorker(QtCore.QObject):
    progress = QtCore.pyqtSignal(float, str)
    done = QtCore.pyqtSignal(object)
    failed = QtCore.pyqtSignal(str)

    def __init__(self, fn):
        super().__init__()
        self.fn = fn

    def run(self):
        try:
            self.done.emit(self.fn(lambda f, t: self.progress.emit(f, t)))
        except Exception as ex:                # noqa: BLE001 — vai para a tela
            traceback.print_exc()
            self.failed.emit(f"{type(ex).__name__}: {ex}")


class StudyPage(QtWidgets.QWidget):
    """estudo das áreas juntas: cada ponto é o ponto de projeto acoplado (massa ↔ asa ↔ EH ↔ tração ↔ MTOW)
    nas altitudes-densidade pedidas; marca o maior MTOW em que a estabilidade fecha e confere no 6GDL"""
    title = "Estudo e ponto de projeto"
    COLS = ("lugar", "valor / avião", "MTOW (kg)", "fecha?", "limita", "roda (m/s)", "sai do chão (m/s)",
            "Δi_h (°)", "trim de decolagem (°)", "C_D trim", "MTOW 6GDL (kg)")

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        from aerosim.design import study as sd
        self.sd = sd
        self.state = state
        self.rows: list[dict] = []
        self._thread = None
        self._cancel = False
        self._plots_sig = None
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.setChildrenCollapsible(False)
        QtWidgets.QHBoxLayout(self).addWidget(split)
        left_in = QtWidgets.QWidget()
        lv = QtWidgets.QVBoxLayout(left_in)
        lv.addWidget(ReqBar(state))
        t = QtWidgets.QLabel(f"<b>{self.title}</b>" + HELP_MARK)
        t.setToolTip(sd.__doc__)
        lv.addWidget(t)
        self.form_box = QtWidgets.QVBoxLayout()
        lv.addLayout(self.form_box)
        self.form = None
        self.run_b = QtWidgets.QPushButton("▶ Rodar estudo")
        self.stop_b = QtWidgets.QPushButton("■ Parar")
        self.stop_b.setEnabled(False)
        self.six_b = QtWidgets.QPushButton("★ Conferir os marcados no 6GDL")
        self.six_all_b = QtWidgets.QPushButton("★ Conferir todos no 6GDL")
        self.use_b = QtWidgets.QPushButton("Usar o ponto marcado no rascunho")
        self.send_b = QtWidgets.QPushButton("Mandar o ponto selecionado para a Montagem →")
        self.send_b.setToolTip("o avião da linha selecionada na tabela, no ponto de projeto (massa convergida, asa e EH "
                               "recalibradas, altitude-densidade daquela linha), como mais um avião aberto")
        for b in (self.six_b, self.six_all_b, self.use_b, self.send_b):
            b.setEnabled(False)
        g = QtWidgets.QGridLayout()
        for i, b in enumerate((self.run_b, self.stop_b, self.six_b, self.six_all_b, self.use_b)):
            g.addWidget(b, i // 2, i % 2)
        g.addWidget(self.send_b, 3, 0, 1, 2)
        self.exp_b = QtWidgets.QPushButton("Exportar o estudo (xlsx/csv)…")
        self.exp_b.setEnabled(False)
        self.exp_b.clicked.connect(self.export)
        g.addWidget(self.exp_b, 4, 0, 1, 2)
        lv.addLayout(g)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 1000)
        self.msg = QtWidgets.QLabel()
        self.msg.setWordWrap(True)
        lv.addWidget(self.bar)
        lv.addWidget(self.msg)
        lv.addStretch(1)
        ls = QtWidgets.QScrollArea()
        ls.setWidgetResizable(True)
        ls.setWidget(left_in)
        split.addWidget(ls)
        rs = QtWidgets.QScrollArea()
        rs.setWidgetResizable(True)
        rs.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        right_in = QtWidgets.QWidget()
        self.right = QtWidgets.QVBoxLayout(right_in)
        from ..widgets.view3d import AircraftView
        self.view = AircraftView()
        self.view.move_mode = False
        self.view.setMinimumHeight(230)
        self.view.setMaximumHeight(260)
        self.right.addWidget(self.view)
        self.view_label = QtWidgets.QLabel()
        self.view_label.setStyleSheet("color:#555")
        self.view_label.setWordWrap(True)
        self.right.addWidget(self.view_label)
        self.table = QtWidgets.QTableWidget(0, len(self.COLS))
        self.table.setHorizontalHeaderLabels(self.COLS)
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.table.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.table.setWordWrap(False)
        self.table.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored, QtWidgets.QSizePolicy.Policy.Fixed)
        self.table.setMinimumWidth(300)          # a tabela rola de lado; não empurra a largura dos gráficos
        self.table.currentCellChanged.connect(lambda r, *_: self._show_row(r))
        self.right.addWidget(self.table)
        self.plots = LivePlots([])
        self.right.addWidget(self.plots)
        self.checks = ChecksPanel()
        self.right.addWidget(self.checks)
        self.right.addStretch(1)
        rs.setWidget(right_in)
        split.addWidget(rs)
        split.setSizes([360, 1000])
        self.run_b.clicked.connect(self.start)
        self.stop_b.clicked.connect(lambda: setattr(self, "_cancel", True))
        self.six_b.clicked.connect(lambda: self.check_6dof(marked=True))
        self.six_all_b.clicked.connect(lambda: self.check_6dof(marked=False))
        self.use_b.clicked.connect(self.use_marked)
        self.send_b.clicked.connect(self.send_selected)
        state.designChanged.connect(self._on_design)
        self.build()
        self.show_saved()

    def _on_design(self, st):
        if st in ("load", "guardou", "apagou"):
            self.build()
        if st == "load":
            self.rows = []
            self.show_saved()

    def build(self):
        d = self.state.design
        names = (self.sd.DRAFT,) + tuple(a.name for a in d.aircraft)
        if d.study.aircraft not in names:
            d.study.aircraft = self.sd.DRAFT
        if self.form is not None:
            self.form_box.removeWidget(self.form)
            self.form.hide()
            self.form.setParent(None)
            self.form.deleteLater()
        self.form = DataclassForm(d.study, choices={"aircraft": names})
        self.form.changed.connect(lambda *_: self.state.design_edited(self.title))
        self.form_box.addWidget(self.form)

    # ------------------------------------------------------------------ rodar em segundo plano
    def _go(self, fn, after):
        if self._thread is not None:
            return
        self._cancel = False
        for b in (self.run_b, self.six_b, self.six_all_b, self.use_b, self.send_b, self.exp_b):
            b.setEnabled(False)
        self.stop_b.setEnabled(True)
        self.bar.setValue(0)
        self._thread = QtCore.QThread(self)
        self._worker = _StudyWorker(fn)
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.progress.connect(lambda f, t: (self.bar.setValue(int(1000 * f)), self.msg.setText(t)))
        self._worker.done.connect(after)
        self._worker.failed.connect(lambda t: self.msg.setText(f"<span style='color:#b00'>{t}</span>"))
        for sig in (self._worker.done, self._worker.failed):
            sig.connect(self._finish)
        self._thread.start()

    def _finish(self, *_):
        self._thread.quit()
        self._thread.wait()
        self._thread = None
        self.stop_b.setEnabled(False)
        self.run_b.setEnabled(True)
        has = bool(self.rows)
        for b in (self.six_b, self.six_all_b, self.use_b, self.send_b, self.exp_b):
            b.setEnabled(has)
        self.bar.setValue(1000)

    def start(self):
        d, sp = self.state.design, copy.deepcopy(self.state.design.study)
        cat, be = self.state.catalog, self.state.manager.backend
        self._sp = sp
        self._go(lambda prog: self.sd.run(d, sp, cat, be, prog, lambda: self._cancel), self._done)

    def _done(self, rows):
        self.rows = rows or []
        self.msg.setText(f"{len(self.rows)} pontos de projeto" if self.rows else "nada para estudar: guarde um avião "
                         "na etapa Motores (ou monte o rascunho dela)")
        self._keep_run()
        self.redraw()

    def _keep_run(self):
        """os dados de simulação ficam no projeto (e se gravam com ele)"""
        if self.rows:
            sp = getattr(self, "_sp", self.state.design.study)
            self.state.design.keep_study(self.sd.to_run(sp, self.rows))
            self.state.design_edited("estudo")

    def show_saved(self):
        """o último estudo guardado no projeto (ao abrir o projeto ou a página)"""
        runs = self.state.design.studies
        if self._thread is not None or not runs:
            return
        self._sp, self.rows = self.sd.from_run(runs[-1])
        self.msg.setText(f"estudo guardado no projeto: {self._sp.mode}"
                         + (f" — {self._sp.variable}" if self._sp.mode == self.sd.MODES[0] else ""))
        for b in (self.six_b, self.six_all_b, self.use_b, self.send_b, self.exp_b):
            b.setEnabled(True)
        self.redraw()

    def export(self):
        from ..tabs.simulation_tab import export_result
        sp = getattr(self, "_sp", self.state.design.study)
        if not self.rows:
            return
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Exportar o estudo", "estudo.xlsx", "Excel (*.xlsx);;CSV (*.csv)")
        if path:
            _, res = self.sd.result(self.rows, sp)
            res.series["estudo"] = self.sd.table(self.rows)
            self.msg.setText(export_result(res, path))

    def _ensure(self, r):
        sp = getattr(self, "_sp", self.state.design.study)
        return self.sd.ensure(r, self.state.design, sp, self.state.catalog, self.state.manager.backend)

    def check_6dof(self, marked: bool):
        best = self.sd.best_rows(self.rows)
        todo = list(best.values()) if marked else [r for r in self.rows if math.isfinite(r["mtow"])]
        d, man, cat = self.state.design, self.state.manager, self.state.catalog

        def fn(prog):
            for r in todo:
                self._ensure(r)
            self.sd.check_many(todo, d, man, cat, prog, lambda: self._cancel)
            return self.rows
        self._go(fn, lambda _rows: (self.msg.setText("conferido no 6GDL (estrelas no gráfico)"), self._keep_run(),
                                    self.redraw()))

    def use_marked(self):
        best = self.sd.best_rows(self.rows)
        if not best:
            return
        r = self._ensure(next(iter(best.values())))
        d = self.state.design
        sp = getattr(self, "_sp", d.study)
        if sp.mode == self.sd.MODES[1]:
            d.power_draft = copy.deepcopy(r["_cand"].params)
            self.msg.setText(f"'{r['name']}' carregado no rascunho da etapa Motores")
        else:
            stage, field = self.sd.VARIABLES[sp.variable]
            target = {"power": d.power_draft, "tail": d.tail_draft, "wing": d.wing_draft}[stage]
            setattr(target, field, float(r["x"]))
            where = {"power": "Motores e montagem", "tail": "Empenagem e comandos", "wing": "Asa"}[stage]
            self.msg.setText(f"{sp.variable} = {r['x']:g} no rascunho da etapa {where}"
                             + ("" if stage == "power" else " — guarde de novo lá para seguir"))
        self.state.design_edited("ponto")

    def send_selected(self):
        """o ponto de projeto da linha selecionada vai para a Montagem (e para 'meus aviões')"""
        from aerosim.design import power as pw
        i = self.table.currentRow()
        if not (0 <= i < len(self.rows)):
            return
        r = self._ensure(self.rows[i])
        d = self.state.design
        sp = getattr(self, "_sp", d.study)
        ac, _ = pw.assemble(r["_cand"], r["_req"], d.rules, self.state.catalog, d.airfoil_map())
        base = r["_cand"].params.name
        if sp.mode == self.sd.MODES[0]:
            base += f", {sp.variable.split(' (')[0]} {r['x']:g}"
        ac.name = f"{base} ({r['place']})"
        send_to_assembly(self.state, ac, self)

    # ------------------------------------------------------------------ mostrar
    def redraw(self):
        sp = getattr(self, "_sp", self.state.design.study)
        specs, res = self.sd.result(self.rows, sp)
        sig = tuple(s.key for s in specs)
        if sig != self._plots_sig:
            new = LivePlots(specs, columns=2, row_height=290)
            self.right.replaceWidget(self.plots, new)
            self.plots.hide()
            self.plots.setParent(None)
            self.plots.deleteLater()
            self.plots = new
            self._plots_sig = sig
        self.plots.show_result(res)
        self.checks.show_checks(res.checks)
        self.checks.show_summary(res.summary)
        best = {id(r) for r in self.sd.best_rows(self.rows).values()}
        from PyQt6 import QtGui
        f = lambda v: "—" if not (isinstance(v, float) and math.isfinite(v)) else f"{v:.2f}"
        self.table.setRowCount(len(self.rows))
        for i, r in enumerate(self.rows):
            vals = (r["place"], r["name"], f(r["mtow"]), "sim" if r["ok"] else "não", r["why"] or r["limit"], f(r["v_rot"]),
                    f(r["v_lof"]), f(r["dih"]), f(r["hold"]), f"{r['cd_trim']:.4f}", f(r["mtow6"]))
            for j, v in enumerate(vals):
                it = QtWidgets.QTableWidgetItem(v)
                if r["why"]:
                    it.setToolTip(r["why"])
                if id(r) in best:
                    it.setBackground(QtGui.QColor("#fff3c4"))
                elif not r["ok"]:
                    it.setForeground(QtGui.QColor("#a33"))
                self.table.setItem(i, j, it)
        self.table.resizeRowsToContents()
        self.table.setFixedHeight(self.table.horizontalHeader().height() + 22 +
                                  sum(self.table.rowHeight(i) for i in range(len(self.rows))))
        bi = next((i for i, r in enumerate(self.rows) if id(r) in best), 0 if self.rows else -1)
        self._show_row(bi)

    def _show_row(self, i):
        if not (0 <= i < len(self.rows)):
            return
        r = self.rows[i]
        if "_cand" not in r:
            try:
                self._ensure(r)
            except Exception as ex:
                self.view_label.setText(str(ex))
                return
        from aerosim.design import power as pw
        d = self.state.design
        try:
            ac, asm = pw.assemble(r["_cand"], r["_req"], d.rules, self.state.catalog, d.airfoil_map())
        except Exception:
            return
        self.view.set_aircraft(ac)
        self.view.clear_markers()
        self.view.set_markers(cg=[asm["x_cg_target"], 0.0, 0.0])
        self.view_label.setText(f"{r['place']} · {r['name']} · massa de projeto {r['mtow']:.2f} kg · PV {r['pv']:.2f} kg"
                                f" · asa calada a {r['incidence']:.1f}°, EH a {r['i_h'] + r['dih']:.1f}°")
