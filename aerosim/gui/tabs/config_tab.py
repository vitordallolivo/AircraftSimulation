"""Aba de configuração: aeronave em 3D (80 %) e painel de componentes (20 %).

No painel: lista de componentes com botões de adicionar/remover, editor do componente
selecionado (sliders + campos), seções e comandos das superfícies, perfil .dat, escolha
de motor/hélice/bateria do catálogo, curva de tração, vento com botões de direção, e o
resumo de massa, CG e margem estática.
"""
from __future__ import annotations

import copy

import pyqtgraph as pg
from PyQt6 import QtCore, QtWidgets

from aerosim.model.aircraft import (ControlSurface, LiftingSurface, PropulsionUnit, SloshTank, WingSection,
                                    rect_sections)
from aerosim.model.airfoil import Airfoil, read_dat
from aerosim.model.mission import Leg, MissionEvent

from ..state import AppState
from ..widgets.param_slider import CONTROL_KINDS, EVENT_KINDS, LEG_KINDS, DataclassForm, ParamSlider
from ..widgets.view3d import AircraftView

NONGEOM = [("mass", "Massa e inércia"), ("environment", "Ambiente"), ("takeoff", "Decolagem"),
           ("autopilot", "Piloto automático"), ("sim", "Integração"), ("mission", "Percurso")]


class ConfigTab(QtWidgets.QWidget):
    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        self.form: DataclassForm | None = None
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        QtWidgets.QHBoxLayout(self).addWidget(split)

        # ---------------- 3D ----------------
        left = QtWidgets.QWidget()
        lv = QtWidgets.QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        bar = QtWidgets.QHBoxLayout()
        self.move_chk = QtWidgets.QCheckBox("mover com o mouse")
        self.move_chk.setChecked(True)
        self.lock = QtWidgets.QComboBox()
        self.lock.addItems(["plano da tela", "só x", "só y", "só z"])
        self.info = QtWidgets.QLabel()
        bar.addWidget(self.move_chk)
        bar.addWidget(QtWidgets.QLabel("arraste:"))
        bar.addWidget(self.lock)
        bar.addStretch(1)
        bar.addWidget(self.info)
        lv.addLayout(bar)
        self.view = AircraftView()
        lv.addWidget(self.view, 1)
        legend = QtWidgets.QLabel("● vermelho: CG   | verde: ponto neutro   → azul: vento   "
                                  "(clique num componente para selecionar e arraste para mover)")
        legend.setStyleSheet("color: #555; font-size: 10px")
        lv.addWidget(legend)
        split.addWidget(left)

        # ---------------- painel ----------------
        panel = QtWidgets.QWidget()
        pv = QtWidgets.QVBoxLayout(panel)
        pv.setContentsMargins(4, 4, 4, 4)
        pv.addWidget(self._wind_box())
        self.comp_list = QtWidgets.QListWidget()
        self.comp_list.setMaximumHeight(190)
        pv.addWidget(QtWidgets.QLabel("<b>Componentes</b>"))
        pv.addWidget(self.comp_list)
        pv.addLayout(self._add_buttons())
        self.editor_area = QtWidgets.QScrollArea()
        self.editor_area.setWidgetResizable(True)
        pv.addWidget(self.editor_area, 1)
        self.summary = QtWidgets.QLabel()
        self.summary.setWordWrap(True)
        self.summary.setStyleSheet("background:#f0f3f8; padding:4px")
        pv.addWidget(self.summary)
        split.addWidget(panel)
        split.setStretchFactor(0, 8)
        split.setStretchFactor(1, 2)
        split.setSizes([1100, 330])

        self.comp_list.currentItemChanged.connect(self._on_list)
        self.view.componentSelected.connect(self._on_pick)
        self.view.componentMoved.connect(self._on_moved)
        self.move_chk.toggled.connect(lambda on: setattr(self.view, "move_mode", on))
        self.lock.currentIndexChanged.connect(
            lambda i: setattr(self.view, "axis_lock", ("plano", "x", "y", "z")[i]))
        state.changed.connect(self._on_state)
        self._timer = QtCore.QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._update_summary)
        self._geo_timer = QtCore.QTimer(self)
        self._geo_timer.setSingleShot(True)
        self._geo_timer.timeout.connect(self.view.rebuild)
        self._reload()

    # ------------------------------------------------------------------ vento
    def _wind_box(self):
        box = QtWidgets.QGroupBox("Vento")
        g = QtWidgets.QGridLayout(box)
        env = self.state.aircraft.environment
        self.wind_speed = ParamSlider("velocidade", env.wind_speed, 0, 20, 0.1, "m/s")
        self.wind_dir = QtWidgets.QDial()
        self.wind_dir.setRange(-180, 180)
        self.wind_dir.setWrapping(True)
        self.wind_dir.setNotchesVisible(True)
        self.wind_dir.setMaximumSize(70, 70)
        self.wind_lbl = QtWidgets.QLabel()
        left_b = QtWidgets.QPushButton("⟲ 15°")
        right_b = QtWidgets.QPushButton("15° ⟳")
        g.addWidget(self.wind_speed, 0, 0, 1, 3)
        g.addWidget(left_b, 1, 0)
        g.addWidget(self.wind_dir, 1, 1)
        g.addWidget(right_b, 1, 2)
        g.addWidget(self.wind_lbl, 2, 0, 1, 3)
        self.wind_speed.valueChanged.connect(self._wind_changed)
        self.wind_dir.valueChanged.connect(self._wind_changed)
        left_b.clicked.connect(lambda: self._rotate_wind(-15))
        right_b.clicked.connect(lambda: self._rotate_wind(15))
        return box

    def _rotate_wind(self, d):
        v = self.wind_dir.value() + d
        self.wind_dir.setValue(int((v + 180) % 360 - 180))

    def _wind_changed(self, *_):
        env = self.state.aircraft.environment
        env.wind_speed = self.wind_speed.value()
        env.wind_from = float(self.wind_dir.value())
        self.wind_lbl.setText(f"vem de {env.wind_from:.0f}° (0 = de frente, 90 = da direita)")
        self.view.set_markers(wind=(env.wind_speed, env.wind_from))

    # ------------------------------------------------------------------ adicionar / remover
    def _add_buttons(self):
        g = QtWidgets.QGridLayout()
        defs = [("+ Asa", self._add_wing), ("+ EH", lambda: self._add_tail("htail")),
                ("+ EV", lambda: self._add_tail("vtail")), ("+ Motor", self._add_motor),
                ("+ Tanque", self._add_tank), ("Remover", self._remove)]
        for i, (txt, fn) in enumerate(defs):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            g.addWidget(b, i // 3, i % 3)
        self.chk_boom = QtWidgets.QCheckBox("tubo de cauda")
        self.chk_fus = QtWidgets.QCheckBox("fuselagem")
        self.chk_pay = QtWidgets.QCheckBox("carga")
        self.gear_combo = QtWidgets.QComboBox()
        self.gear_combo.addItems(["tricycle", "conventional", "custom"])
        for w in (self.chk_boom, self.chk_fus, self.chk_pay):
            w.toggled.connect(self._toggles)
        self.gear_combo.currentTextChanged.connect(self._gear_layout)
        g.addWidget(self.chk_boom, 2, 0)
        g.addWidget(self.chk_fus, 2, 1)
        g.addWidget(self.chk_pay, 2, 2)
        g.addWidget(QtWidgets.QLabel("trem:"), 3, 0)
        g.addWidget(self.gear_combo, 3, 1, 1, 2)
        return g

    def _toggles(self, *_):
        ac = self.state.aircraft
        ac.boom.enabled = self.chk_boom.isChecked()
        ac.fuselage.enabled = self.chk_fus.isChecked()
        ac.payload.enabled = self.chk_pay.isChecked()
        self.state.notify("geometry")
        self._fill_list()

    def _gear_layout(self, layout):
        g = self.state.aircraft.gear
        if g.layout == layout:
            return
        if layout == "conventional" and g.steer_x > g.main_x:       # bequilha vai para a cauda
            g.steer_x, g.steer_z, g.main_x = g.skid_x, 0.05, g.main_x + 0.15
        elif layout == "tricycle" and g.steer_x < g.main_x:
            g.steer_x, g.steer_z, g.main_x = 0.45, g.main_z, g.main_x - 0.15
        if layout == "custom" and not g.custom:
            g.custom = copy.deepcopy(g.legs())
        g.layout = layout
        self.state.notify("geometry")

    def _add_wing(self):
        ac = self.state.aircraft
        ac.surfaces.append(LiftingSurface(name=f"asa {len(ac.surfaces)}", role="wing", x=0.1, z=-0.1,
                                          sections=rect_sections(1.0, 0.3), incidence=2.0,
                                          controls=[ControlSurface("aileron", 0.6, 0.95, 0.25)]))
        self._added(f"surface:{len(ac.surfaces) - 1}")

    def _add_tail(self, role):
        ac = self.state.aircraft
        x = ac.boom.x_end + 0.2 if ac.boom.enabled else -0.9
        if role == "htail":
            s = LiftingSurface(name="EH", role="htail", x=x, sections=rect_sections(0.4, 0.2), incidence=-1.0,
                               airfoil=Airfoil("NACA 0012"), controls=[ControlSurface("elevator", 0.0, 1.0, 0.35)],
                               eta=0.9, downwash=True)
        else:
            s = LiftingSurface(name="EV", role="vtail", x=x, sections=rect_sections(0.3, 0.22), symmetric=False,
                               vertical=True, airfoil=Airfoil("NACA 0012"),
                               controls=[ControlSurface("rudder", 0.0, 1.0, 0.35)], eta=0.9)
        ac.surfaces.append(s)
        self._added(f"surface:{len(ac.surfaces) - 1}")

    def _add_motor(self):
        ac = self.state.aircraft
        cat = self.state.catalog
        base = ac.propulsion[-1] if ac.propulsion else None
        u = PropulsionUnit(name=f"motor {len(ac.propulsion) + 1}", x=base.x if base else 0.5,
                           y=(-base.y if base and base.y else 0.5) if base else 0.0, z=base.z if base else 0.0,
                           motor=copy.deepcopy(base.motor if base else cat.motors[0]),
                           propeller=copy.deepcopy(base.propeller if base else cat.propellers[0]),
                           battery=copy.deepcopy(base.battery if base else cat.batteries[0]),
                           sense=-(base.sense if base else -1))
        ac.propulsion.append(u)
        self._added(f"prop:{len(ac.propulsion) - 1}")

    def _add_tank(self):
        ac = self.state.aircraft
        ac.tanks.append(SloshTank(name=f"tanque {len(ac.tanks) + 1}", x=0.05, y=0.0, z=0.0, side=0.1, fill=0.05,
                                  height=0.08))
        self._added(f"tank:{len(ac.tanks) - 1}")

    def _added(self, key):
        self.state.notify("geometry")
        self._fill_list(select=key)

    def _remove(self):
        it = self.comp_list.currentItem()
        if not it:
            return
        key = it.data(QtCore.Qt.ItemDataRole.UserRole)
        kind, _, idx = key.partition(":")
        ac = self.state.aircraft
        if kind == "surface":
            del ac.surfaces[int(idx)]
        elif kind == "prop":
            del ac.propulsion[int(idx)]
        elif kind == "tank":
            del ac.tanks[int(idx)]
        elif kind == "boom":
            ac.boom.enabled = False
        elif kind == "fuselage":
            ac.fuselage.enabled = False
        elif kind == "payload":
            ac.payload.enabled = False
        else:
            return
        self.view.selected = None
        self.state.notify("geometry")
        self._reload()

    # ------------------------------------------------------------------ lista e seleção
    def _reload(self):
        ac = self.state.aircraft
        for w, v in ((self.chk_boom, ac.boom.enabled), (self.chk_fus, ac.fuselage.enabled),
                     (self.chk_pay, ac.payload.enabled)):
            w.blockSignals(True)
            w.setChecked(v)
            w.blockSignals(False)
        self.gear_combo.blockSignals(True)
        self.gear_combo.setCurrentText(ac.gear.layout)
        self.gear_combo.blockSignals(False)
        env = ac.environment
        self.wind_speed.setValue(env.wind_speed)
        self.wind_dir.blockSignals(True)
        self.wind_dir.setValue(int(env.wind_from))
        self.wind_dir.blockSignals(False)
        self._wind_changed()
        self.view.set_aircraft(ac)
        self._fill_list()
        self._timer.start(50)

    def _fill_list(self, select: str | None = None):
        ac = self.state.aircraft
        cur = select or (self.comp_list.currentItem().data(QtCore.Qt.ItemDataRole.UserRole)
                         if self.comp_list.currentItem() else None)
        self.comp_list.blockSignals(True)
        self.comp_list.clear()
        items = [(f"surface:{i}", f"✈ {s.name} ({s.role})") for i, s in enumerate(ac.surfaces)]
        items += [(f"prop:{i}", f"⚙ {u.name}") for i, u in enumerate(ac.propulsion)]
        items += [(f"tank:{i}", f"▣ {t.name}") for i, t in enumerate(ac.tanks)]
        if ac.fuselage.enabled:
            items.append(("fuselage", "fuselagem"))
        if ac.boom.enabled:
            items.append(("boom", "tubo de cauda"))
        if ac.payload.enabled:
            items.append(("payload", "carga"))
        items.append(("gear", f"trem de pouso ({ac.gear.layout})"))
        items += [(k, t) for k, t in NONGEOM]
        sel_row = 0
        for i, (k, t) in enumerate(items):
            it = QtWidgets.QListWidgetItem(t)
            it.setData(QtCore.Qt.ItemDataRole.UserRole, k)
            self.comp_list.addItem(it)
            if k == cur:
                sel_row = i
        self.comp_list.blockSignals(False)
        self.comp_list.setCurrentRow(sel_row)

    def _on_list(self, cur, _prev):
        if cur is None:
            return
        key = cur.data(QtCore.Qt.ItemDataRole.UserRole)
        self.view.select(key if ":" in key or key in ("fuselage", "boom", "payload", "gear") else None)
        self._edit(key)

    def _on_pick(self, key):
        for i in range(self.comp_list.count()):
            if self.comp_list.item(i).data(QtCore.Qt.ItemDataRole.UserRole) == key:
                self.comp_list.setCurrentRow(i)
                return

    def _on_moved(self, key):
        if self.form is not None:
            self.form.refresh()
        self._timer.start(250)

    def _on_state(self, reason):
        if reason == "load":
            self._reload()
            return
        self._geo_timer.start(30)
        self._timer.start(300)

    # ------------------------------------------------------------------ editores
    def _changed(self, field=""):
        if field == "name":
            self._fill_list()
        self.state.notify("geometry")

    def _edit(self, key):
        ac = self.state.aircraft
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setSpacing(4)
        kind, _, idx = key.partition(":")
        self.form = None
        if kind == "surface":
            s = ac.surfaces[int(idx)]
            self.form = DataclassForm(s, exclude=("sections", "controls", "airfoil"))
            v.addWidget(self.form)
            v.addWidget(self._sections_editor(s))
            v.addWidget(self._controls_editor(s))
            v.addWidget(self._airfoil_editor(s))
        elif kind == "prop":
            u = ac.propulsion[int(idx)]
            self.form = DataclassForm(u, exclude=("motor", "propeller", "battery"))
            v.addWidget(self.form)
            v.addWidget(self._propulsion_choice(u))
        elif kind == "tank":
            self.form = DataclassForm(ac.tanks[int(idx)])
            v.addWidget(self.form)
            self._tank_info = QtWidgets.QLabel()
            v.addWidget(self._tank_info)
        elif kind in ("fuselage", "boom", "payload"):
            self.form = DataclassForm(getattr(ac, {"boom": "boom"}.get(kind, kind)))
            v.addWidget(self.form)
        elif kind == "gear":
            self.form = DataclassForm(ac.gear, exclude=("custom",))
            v.addWidget(self.form)
            if ac.gear.layout == "custom":
                v.addWidget(self._list_editor("pernas (custom)", ac.gear.custom, lambda: type(ac.gear.custom[0])()
                                              if ac.gear.custom else None, {"kind": ("steer", "main", "skid")}))
        elif kind == "mass":
            self.form = DataclassForm(ac.mass, exclude=("items",))
            v.addWidget(self.form)
            from aerosim.model.aircraft import PointMass
            v.addWidget(self._list_editor("massas pontuais", ac.mass.items, PointMass, {}))
        elif kind == "mission":
            self.form = DataclassForm(ac.mission, exclude=("legs", "events"))
            v.addWidget(self.form)
            v.addWidget(self._list_editor("pernas", ac.mission.legs, Leg, {"kind": LEG_KINDS}))
            v.addWidget(self._list_editor("eventos", ac.mission.events, MissionEvent, {"kind": EVENT_KINDS}))
        else:
            self.form = DataclassForm(getattr(ac, kind))
            v.addWidget(self.form)
        if self.form is not None:
            self.form.changed.connect(self._changed)
        v.addStretch(1)
        self.editor_area.setWidget(w)

    def _sections_editor(self, s: LiftingSurface):
        box = QtWidgets.QGroupBox("Seções (raiz → ponta)")
        v = QtWidgets.QVBoxLayout(box)
        table = QtWidgets.QTableWidget(0, 4)
        table.setHorizontalHeaderLabels(["y (m)", "corda (m)", "recuo BA (m)", "torção (°)"])
        table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        table.setMaximumHeight(150)

        def fill():
            table.blockSignals(True)
            table.setRowCount(len(s.sections))
            for r, sec in enumerate(s.sections):
                for c, a in enumerate(("y", "chord", "x_offset", "twist")):
                    table.setItem(r, c, QtWidgets.QTableWidgetItem(f"{getattr(sec, a):.4g}"))
            table.blockSignals(False)
            info.setText(f"S = {s.area:.4f} m²   b = {s.span:.3f} m   AR = {s.aspect_ratio:.2f}   c̄ = {s.mac:.3f} m")

        def edited(item):
            try:
                val = float(item.text().replace(",", "."))
            except ValueError:
                return
            setattr(s.sections[item.row()], ("y", "chord", "x_offset", "twist")[item.column()], val)
            fill()
            self.state.notify("geometry")

        def add():
            last = s.sections[-1] if s.sections else WingSection()
            s.sections.append(WingSection(last.y + 0.2, last.chord * 0.85, last.x_offset + 0.03, last.twist))
            fill()
            self.state.notify("geometry")

        def rem():
            if len(s.sections) > 2:
                s.sections.pop(table.currentRow() if table.currentRow() >= 0 else -1)
                fill()
                self.state.notify("geometry")
        info = QtWidgets.QLabel()
        table.itemChanged.connect(edited)
        v.addWidget(table)
        h = QtWidgets.QHBoxLayout()
        for txt, fn in (("+ seção", add), ("− seção", rem)):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            h.addWidget(b)
        v.addLayout(h)
        v.addWidget(info)
        fill()
        return box

    def _list_editor(self, title, items: list, factory, choices: dict):
        """lista de dataclasses: um formulário por item, + / −"""
        box = QtWidgets.QGroupBox(title)
        v = QtWidgets.QVBoxLayout(box)
        holder = QtWidgets.QVBoxLayout()
        v.addLayout(holder)

        def fill():
            while holder.count():
                w = holder.takeAt(0).widget()
                if w:
                    w.deleteLater()
            for i, it in enumerate(items):
                gb = QtWidgets.QGroupBox(f"{i}")
                gl_ = QtWidgets.QVBoxLayout(gb)
                f = DataclassForm(it, choices=choices)
                f.changed.connect(lambda *_: self.state.notify("geometry"))
                gl_.addWidget(f)
                rb = QtWidgets.QPushButton("remover")
                rb.clicked.connect(lambda _=False, k=i: (items.pop(k), fill(), self.state.notify("geometry")))
                gl_.addWidget(rb)
                holder.addWidget(gb)

        def add():
            new = factory() if callable(factory) else None
            if new is None:
                return
            items.append(new)
            fill()
            self.state.notify("geometry")
        b = QtWidgets.QPushButton("+ adicionar")
        b.clicked.connect(add)
        v.addWidget(b)
        fill()
        return box

    def _controls_editor(self, s: LiftingSurface):
        default = {"wing": "aileron", "htail": "elevator", "vtail": "rudder"}.get(s.role, "aileron")
        return self._list_editor("Comandos (aileron, profundor, leme, elevon...)", s.controls,
                                 lambda: ControlSurface(default, 0.6, 1.0, 0.25), {"kind": CONTROL_KINDS})

    def _airfoil_editor(self, s: LiftingSurface):
        box = QtWidgets.QGroupBox("Perfil")
        v = QtWidgets.QVBoxLayout(box)
        f = DataclassForm(s.airfoil, exclude=("coords", "path"))
        f.changed.connect(lambda k: (setattr(s.airfoil, "coords", []) if k == "name" else None, plot(),
                                     self.state.notify("geometry")))
        v.addWidget(f)
        lbl = QtWidgets.QLabel(s.airfoil.path or "(NACA gerado pelo nome)")
        lbl.setWordWrap(True)
        b = QtWidgets.QPushButton("Carregar .dat…")
        pw = pg.PlotWidget()
        pw.setMaximumHeight(110)
        pw.setAspectLocked(True)
        pw.hideAxis("left")

        def plot():
            c = s.airfoil.outline()
            pw.clear()
            pw.plot(c[:, 0], c[:, 1], pen=pg.mkPen("#1f77b4", width=2))
            a0, cm = s.airfoil.zero_lift_angle(), s.airfoil.moment_ac()
            info.setText(f"α_L0 = {a0:.2f}°   C_m,ac = {cm:.3f}  (perfil fino)")

        def load():
            path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Perfil", "", "Perfis (*.dat *.txt)")
            if not path:
                return
            name, coords = read_dat(path)
            s.airfoil.path = path
            s.airfoil.name = name
            s.airfoil.coords = coords.tolist()
            lbl.setText(path)
            plot()
            self.state.notify("geometry")
        info = QtWidgets.QLabel()
        b.clicked.connect(load)
        v.addWidget(b)
        v.addWidget(lbl)
        v.addWidget(pw)
        v.addWidget(info)
        plot()
        return box

    def _propulsion_choice(self, u: PropulsionUnit):
        box = QtWidgets.QGroupBox("Motor, hélice e bateria (catálogo)")
        g = QtWidgets.QFormLayout(box)
        cat = self.state.catalog
        combos = {}
        for attr, items, label in (("motor", cat.motors, "motor"), ("propeller", cat.propellers, "hélice"),
                                   ("battery", cat.batteries, "bateria")):
            cb = QtWidgets.QComboBox()
            names = [it.name for it in items]
            cur = getattr(u, attr).name
            if cur not in names:
                names.insert(0, cur)
            cb.addItems(names)
            cb.setCurrentText(cur)
            g.addRow(label, cb)
            combos[attr] = (cb, items)
        info = QtWidgets.QLabel()
        info.setWordWrap(True)

        def describe():
            m, p, b = u.motor, u.propeller, u.battery
            info.setText(f"{m.Kv:.0f} Kv, {m.Imax:.0f} A, {m.mass * 1000:.0f} g<br>"
                         f"D = {p.D * 39.37:.1f}\", passo {p.pitch * 39.37:.1f}\", {len(p.J)} pontos J<br>"
                         f"{b.cells}S, {b.Voc:.1f} V, {b.capacity_mAh:.0f} mAh<br><i>{p.source}</i>")

        def pick(attr):
            cb, items = combos[attr]
            it = next((x for x in items if x.name == cb.currentText()), None)
            if it is not None:
                setattr(u, attr, copy.deepcopy(it))
                describe()
                self.state.notify("geometry")
        for attr in combos:
            combos[attr][0].currentTextChanged.connect(lambda _t, a=attr: pick(a))
        g.addRow(info)
        bt = QtWidgets.QPushButton("Curva de tração × velocidade…")
        bt.clicked.connect(self._thrust_dialog)
        g.addRow(bt)
        describe()
        return box

    def _thrust_dialog(self):
        res = self.state.manager.run("thrust", self.state.aircraft, {"thr": "1.0, 0.75, 0.5"})
        dlg = QtWidgets.QDialog(self)
        dlg.setWindowTitle("Tração × velocidade (equilíbrio de rotação do motor)")
        dlg.resize(900, 600)
        lay = QtWidgets.QVBoxLayout(dlg)
        gw = pg.GraphicsLayoutWidget()
        lay.addWidget(gw)
        cols = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b"]
        for i, (key, title, unit) in enumerate((("T", "Tração", "N"), ("P_elec", "Potência elétrica", "W"),
                                                ("I", "Corrente", "A"), ("eta_prop", "Eficiência da hélice", "—"))):
            p = gw.addPlot(row=i // 2, col=i % 2, title=title)
            p.addLegend(labelTextSize="8pt")
            p.showGrid(x=True, y=True, alpha=0.3)
            p.setLabel("bottom", "V (m/s)")
            p.setLabel("left", unit)
            for j, (name, tab) in enumerate(res.series.items()):
                p.plot(tab["V"], tab[key], pen=pg.mkPen(cols[j % len(cols)], width=2), name=name)
        dlg.exec()

    # ------------------------------------------------------------------ resumo
    def _update_summary(self):
        ac = self.state.aircraft
        try:
            from aerosim.manager.calibration import static_characteristics
            info = static_characteristics(self.state.manager.backend, ac)
        except Exception as e:      # configuração inválida no meio da edição
            self.summary.setText(f"<span style='color:#b00'>{e}</span>")
            return
        cg = info["cg"]
        self.view.set_markers(cg=cg, np_x=info["x_np"])
        sm = info["static_margin"] * 100
        cor = "#080" if 5 <= sm <= 30 else "#b00"
        self.summary.setText(
            f"<b>m</b> = {info['mass']:.3f} kg   <b>CG</b> = ({cg[0]:.3f}, {cg[1]:.3f}, {cg[2]:.3f}) m<br>"
            f"<b>margem estática</b> = <span style='color:{cor}'>{sm:.1f} %</span>   x_NP = {info['x_np']:.3f} m<br>"
            f"C_Lα = {info['CLa']:.2f}/rad   C_L0 = {info['CL0']:.3f}   C_Lmax = {info['CLmax']:.2f}<br>"
            f"V_estol = {info['Vs']:.2f} m/s   S = {info['Sref']:.3f} m²   b = {info['bref']:.2f} m")
        self.info.setText(f"{ac.name}  —  {len(ac.surfaces)} superfícies, {len(ac.propulsion)} motores, "
                          f"{len(ac.tanks)} tanques")
        if hasattr(self, "_tank_info") and self._tank_info is not None:
            try:
                key = self.comp_list.currentItem().data(QtCore.Qt.ItemDataRole.UserRole)
                t = ac.tanks[int(key.split(":")[1])]
                self._tank_info.setText(f"líquido: {t.liquid_mass:.3f} kg")
            except Exception:
                pass

