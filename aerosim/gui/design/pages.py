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
import os
import traceback

from PyQt6 import QtCore, QtWidgets

from aerosim.design import airfoils as afm
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


class RequirementsDialog(QtWidgets.QDialog):
    """requisitos e regras do projeto (editados no lugar; cada mudança refaz as etapas)"""

    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Requisitos e regras de projeto")
        self.resize(560, 640)
        v = QtWidgets.QVBoxLayout(self)
        tabs = QtWidgets.QTabWidget()
        for obj, title in ((state.design.requirements, "Requisitos"), (state.design.rules, "Regras de projeto")):
            sc = QtWidgets.QScrollArea()
            sc.setWidgetResizable(True)
            f = DataclassForm(obj)
            f.changed.connect(lambda *_: state.design_edited("requisitos"))
            sc.setWidget(f)
            tabs.addTab(sc, title)
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
        b = QtWidgets.QPushButton("Requisitos…")
        b.setToolTip("requisitos (massa, velocidades, AD, envergadura, pista) e regras de projeto (massas, fuselagem, trem)")
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
        st = self.state.projects
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
            QtWidgets.QMessageBox.warning(self, "Salvar", f"não salvei em 'meus aviões': {ex}")
        self.state.add(ac, path)
        win = self.window()
        if hasattr(win, "show_assembly"):
            win.show_assembly()
