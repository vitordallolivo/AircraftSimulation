"""Aba de configuração em três colunas:

  esquerda   vento, lista de componentes (asa, caudas, motores, tanques, fuselagem, tubo, trem,
             LAPES, pista/mesa/plataforma, massa, ambiente, decolagem, piloto, percurso...), botões de
             adicionar/remover e as informações (massa e CG, inércias, aerodinâmica, W/S, T/W,
             propulsão, trem, pista, LAPES, percurso e avisos)
  centro     a aeronave em 3D (clicar seleciona, arrastar move) e o botão Restaurar
  direita    o editor do componente escolhido (campos numéricos, sem sliders), largo
"""
from __future__ import annotations

import copy
import math
from html import escape

import numpy as np
import pyqtgraph as pg
from PyQt6 import QtCore, QtWidgets

from aerosim.model.aircraft import (DEVICE_KINDS, KIND_MIX, WingDevice, ControlSurface, LiftingSurface, PropulsionUnit, SloshTank, TailBoom, WingSection,
                                    rect_sections)
from aerosim.model.airfoil import Airfoil, read_dat
from aerosim.model.mission import MissionEvent

from ..state import AppState
from ..widgets.param_slider import CONTROL_KINDS, EVENT_KINDS, HELP_MARK, DataclassForm, NumberField
from ..widgets.view3d import AircraftView

# explicação de cada editor: ⓘ no título (passe o mouse)
EDIT_HELP = {
    "ballast": "massa sólida presa na aeronave para acertar o CG; entra na massa, no CG e nas inércias. "
               "Arraste no 3D para mover. Na Missão → MTOW a massa total do avião é que varia (o que passa da montada vai no CG)",
    "takeoff": "na corrida o acelerador vai a cheio; no ponto de acionamento o profundor (ou elevon) vai para a "
               "deflexão de decolagem até o piloto automático assumir. A Missão otimiza esse ponto",
    "airfield": "a aeronave parte de n = 0 rumo ao norte. x_warning: tem de decolar antes desta distância; "
                "z_warning: altura que conta como decolado (na mesa, ≤ 0 = quanto pode afundar)",
    "gear": "tipo: triciclo, convencional (bequilha na cauda) ou custom (pernas livres); trocar o tipo reposiciona "
            "as pernas",
    "mission": "a trajetória (etapas) se edita na aba Missão; aqui ficam o ponto de partida e os eventos",
    "payload": "carga LAPES: massa, posição, baia e paraquedas; a soltura é um evento do percurso",
    "fuselage": "ligue/desligue em 'ativo'",
    "boom": "tubo livre: início (x, y, z), comprimento, inclinação e abertura; tubo duplo = dois tubos (y = ±d). "
            "As superfícies se prendem nele pelo campo 'presa em'",
}

NONGEOM = [("airfield", "🛫 Pista: chão, mesa e plataforma"), ("mass", "Massa e inércia"),
           ("environment", "Ambiente: altitude-densidade (AD) e vento"),
           ("performance", "Envelope de voo: ângulo de cruzeiro, fator de carga"),
           ("takeoff", "Decolagem (acionamento do profundor)"), ("autopilot", "Piloto automático"), ("sim", "Integração"),
           ("mission", "Percurso: partida e eventos")]


def mount_choices(ac, s) -> tuple[str, ...]:
    """onde a superfície `s` pode se prender: solta, na ponta de cada tubo, na ponta de cada outra superfície"""
    return (("solta",) + tuple(f"tubo:{i}" for i in range(len(ac.booms)))
            + tuple(f"ponta:{j}" for j, t in enumerate(ac.surfaces) if t is not s))


class ConfigTab(QtWidgets.QWidget):
    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        self.form: DataclassForm | None = None
        self._tank_info = None
        self.split = split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.setHandleWidth(10)                     # divisórias largas: fáceis de pegar (notebook, Wayland)
        split.setChildrenCollapsible(False)
        split.setStyleSheet("QSplitter::handle { background: #c9d3e0; } QSplitter::handle:hover { background: #7f9cc4; }")
        QtWidgets.QHBoxLayout(self).addWidget(split)

        # ---------------- esquerda: componentes, vento e editor ----------------
        panel = QtWidgets.QWidget()
        pv = QtWidgets.QVBoxLayout(panel)
        pv.setContentsMargins(4, 4, 4, 4)
        pv.addWidget(self._wind_box())
        pv.addWidget(QtWidgets.QLabel("<b>Componentes</b>"))
        self.comp_list = QtWidgets.QListWidget()
        self.comp_list.setMinimumHeight(220)
        pv.addWidget(self.comp_list, 2)
        pv.addLayout(self._add_buttons())
        self.summary = QtWidgets.QTextBrowser()
        self.summary.setStyleSheet("QTextBrowser { background: #f7f9fc; }")
        pv.addWidget(self.summary, 4)
        split.addWidget(panel)

        # ---------------- centro: 3D ----------------
        mid = QtWidgets.QWidget()
        lv = QtWidgets.QVBoxLayout(mid)
        lv.setContentsMargins(0, 0, 0, 0)
        bar = QtWidgets.QHBoxLayout()
        self.move_chk = QtWidgets.QCheckBox("mover")
        self.move_chk.setToolTip("mover componentes arrastando com o mouse")
        self.move_chk.setChecked(True)
        self.lock = QtWidgets.QComboBox()
        self.lock.addItems(["plano da tela", "só x", "só y", "só z"])
        self.restore_b = QtWidgets.QToolButton()
        self.restore_b.setText("↺ Restaurar")
        self.restore_b.setToolButtonStyle(QtCore.Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.restore_b.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        menu = QtWidgets.QMenu(self.restore_b)
        menu.addAction("como estava ao abrir/carregar", self.restore)
        from aerosim.model.templates import TEMPLATES
        for k, f in TEMPLATES.items():
            menu.addAction(f"modelo padrão: {f().name}", lambda k=k: self.restore(k))
        self.restore_b.setMenu(menu)
        self.restore_b.setToolTip("desfaz as mudanças: volta ao estado aberto/carregado ou a um modelo padrão")
        self.info = QtWidgets.QLabel()
        self.info.setWordWrap(True)
        self.info.setMinimumWidth(10)
        self.info.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored, QtWidgets.QSizePolicy.Policy.Preferred)
        from ..widgets.aircraft_panel import FleetBar
        lv.addWidget(FleetBar(state))
        bar.addWidget(self.move_chk)
        bar.addWidget(QtWidgets.QLabel("arraste:"))
        bar.addWidget(self.lock)
        bar.addStretch(1)
        bar.addWidget(self.restore_b)
        lv.addLayout(bar)
        self.view = AircraftView()
        lv.addWidget(self.view, 1)
        legend = QtWidgets.QLabel("● CG (vermelho)   ● ponto neutro (verde)   → vento (azul)" + HELP_MARK)
        legend.setToolTip("clique num componente para selecionar; arraste para mover")
        legend.setStyleSheet("color: #555; font-size: 10px")
        legend.setWordWrap(True)
        lv.addWidget(legend)
        split.addWidget(mid)

        # ---------------- direita: editor do componente escolhido (largo, legível em tela pequena) ----------------
        right = QtWidgets.QWidget()
        right.setMinimumWidth(340)
        rv = QtWidgets.QVBoxLayout(right)
        rv.setContentsMargins(4, 4, 4, 4)
        self.editor_title = QtWidgets.QLabel()
        self.editor_title.setStyleSheet("font-weight: bold; font-size: 13px; color: #1f4e8c")
        rv.addWidget(self.editor_title)
        self.editor_area = QtWidgets.QScrollArea()
        self.editor_area.setWidgetResizable(True)
        self.editor_area.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        rv.addWidget(self.editor_area, 1)
        split.addWidget(right)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 3)
        split.setStretchFactor(2, 4)
        self._sized = False

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

    def showEvent(self, e):
        """na primeira vez que aparece: 3D menor, editor da direita largo (proporcional à tela)"""
        super().showEvent(e)
        if not self._sized:
            self._sized = True
            QtCore.QTimer.singleShot(0, self._apply_sizes)

    def _apply_sizes(self):
        w = max(self.split.width(), 900)
        self.split.setSizes([int(0.25 * w), int(0.30 * w), int(0.45 * w)])

    # ------------------------------------------------------------------ restaurar
    def restore(self, template: str | None = None):
        if template is None:
            ac = copy.deepcopy(self.state.original)
        else:
            from aerosim.model.templates import TEMPLATES
            ac = TEMPLATES[template]()
        self.view.selected = None
        self.state.set_aircraft(ac, self.state.path if template is None else None, keep_original=template is None)

    # ------------------------------------------------------------------ vento
    def _wind_box(self):
        box = QtWidgets.QGroupBox("Vento")
        g = QtWidgets.QGridLayout(box)
        env = self.state.aircraft.environment
        self.wind_speed = NumberField("velocidade a 10 m", env.wind_speed, 0, 40, 0.5, "m/s")
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
        new = (self.wind_speed.value(), float(self.wind_dir.value()))
        if new != (env.wind_speed, env.wind_from):
            self.state.touch()
        env.wind_speed, env.wind_from = new
        self.wind_lbl.setText(f"vem de {env.wind_from:.0f}°")
        self.wind_lbl.setToolTip("0 = de frente, 90 = da direita")
        self.view.set_markers(wind=(env.wind_speed, env.wind_from))

    # ------------------------------------------------------------------ adicionar / remover
    def _add_buttons(self):
        g = QtWidgets.QGridLayout()
        defs = [("+ Asa", self._add_wing), ("+ EH", lambda: self._add_tail("htail")),
                ("+ EV", lambda: self._add_tail("vtail")), ("+ Motor", self._add_motor),
                ("+ Tubo", self._add_boom), ("+ Tanque", self._add_tank), ("Remover", self._remove)]
        for i, (txt, fn) in enumerate(defs):
            b = QtWidgets.QPushButton(txt)
            b.clicked.connect(fn)
            g.addWidget(b, i // 3, i % 3)
        return g

    @staticmethod
    def _gear_layout(g, old):
        """trocou o tipo do trem no editor: reposiciona as pernas (bequilha ↔ cauda)"""
        new = g.layout
        if new == old:
            return
        if new == "conventional" and g.steer_x > g.main_x:       # bequilha vai para a cauda
            g.steer_x, g.steer_z, g.main_x = g.skid_x, 0.05, g.main_x + 0.15
        elif new == "tricycle" and g.steer_x < g.main_x:
            g.steer_x, g.steer_z, g.main_x = 0.45, g.main_z, g.main_x - 0.15
        if new == "custom" and not g.custom:
            g.layout = old
            g.custom = copy.deepcopy(g.legs())
            g.layout = new

    def _add_wing(self):
        ac = self.state.aircraft
        ac.surfaces.append(LiftingSurface(name=f"asa {len(ac.surfaces)}", role="wing", x=0.1, z=-0.1,
                                          sections=rect_sections(1.0, 0.3), incidence=2.0,
                                          controls=[ControlSurface("aileron", 0.6, 0.95, 0.25)]))
        self._added(f"surface:{len(ac.surfaces) - 1}")

    def _add_boom(self):
        ac = self.state.aircraft
        base = ac.booms[-1] if ac.booms else None
        b = copy.deepcopy(base) if base else TailBoom(x_start=-0.2, length=0.8)
        if base is not None:
            b.y, b.yaw = (-base.y, -base.yaw) if base.y or base.yaw else (base.y + 0.3, base.yaw)   # o par do tubo duplo
        b.name = f"tubo {len(ac.booms) + 1}"
        ac.booms.append(b)
        self._added(f"boom:{len(ac.booms) - 1}")

    def _add_tail(self, role):
        ac = self.state.aircraft
        x = ac.boom.x_end + 0.2 if ac.boom.enabled else -0.9
        mount = "tubo:0" if ac.booms else ""         # com tubo, nasce presa na ponta dele (muda em 'presa em')
        if role == "htail":
            s = LiftingSurface(name="EH", role="htail", x=x, mount=mount, sections=rect_sections(0.4, 0.2),
                               incidence=-1.0, airfoil=Airfoil("NACA 0012"), controls=[ControlSurface("elevator", 0.0, 1.0, 0.35)],
                               eta=0.9, downwash=True)
        else:
            s = LiftingSurface(name="EV", role="vtail", x=x, mount=mount, sections=rect_sections(0.3, 0.22), symmetric=False,
                               vertical=True, airfoil=Airfoil("NACA 0012"),
                               controls=[ControlSurface("rudder", 0.0, 1.0, 0.35)], eta=0.9)
        ac.surfaces.append(s)
        ac.apply_constraints()
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
        ac.tanks.append(SloshTank(name=f"tanque {len(ac.tanks) + 1}", x=0.05, y=0.0, z=0.0, side=0.1, volume=2.0,
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
            i = int(idx)
            del ac.booms[i]
            for s in ac.surfaces:                      # quem estava preso nele fica solto; os outros, renumerados
                k, _, j = s.mount.partition(":")
                if k == "tubo" and j.isdigit():
                    s.mount = "" if int(j) == i else (f"tubo:{int(j) - 1}" if int(j) > i else s.mount)
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
        off = lambda on: "" if on else " (desligado)"
        items.append(("fuselage", "fuselagem" + off(ac.fuselage.enabled)))
        items += [(f"boom:{i}", f"┃ {b.name}" + off(b.enabled)) for i, b in enumerate(ac.booms)]
        items.append(("payload", "📦 LAPES: carga e soltura" + ("" if ac.payload.enabled else " (desligado)")))
        items.append(("ballast", "⚖ Lastro" + (f" ({ac.ballast.mass:g} kg)" if ac.ballast.enabled else " (desligado)")))
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
        hp = EDIT_HELP.get(key.partition(":")[0], "")
        self.editor_title.setText(escape(cur.text()) + (HELP_MARK if hp else ""))
        self.editor_title.setToolTip(hp)
        self.view.select(key if ":" in key or key in ("fuselage", "payload", "gear", "ballast") else None)
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
        if field == "layout":
            g = self.state.aircraft.gear
            self._gear_layout(g, self._gear_prev)
            self._gear_prev = g.layout
            self.state.notify("geometry")
            self._fill_list()          # reabre o editor (pernas custom aparecem/somem)
            return
        if field == "density_altitude":
            env = self.state.aircraft.environment
            env.set_density_altitude(env.density_altitude)
            self._show_rho()
        if field in ("name", "enabled"):
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
            self.form = DataclassForm(s, exclude=("sections", "controls", "airfoil", "devices"),
                                      choices={"mount": mount_choices(ac, s)})
            v.addWidget(self.form)
            v.addWidget(self._sections_editor(s))
            v.addWidget(self._controls_editor(s))
            if not s.vertical:
                v.addWidget(self._devices_editor(s))
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
        elif kind == "payload":
            self.form = DataclassForm(ac.payload)
            v.addWidget(self.form)
            v.addWidget(self._drop_editor())
        elif kind == "ballast":
            self.form = DataclassForm(ac.ballast)
            v.addWidget(self.form)
        elif kind == "boom":
            self.form = DataclassForm(ac.booms[int(idx)])
            v.addWidget(self.form)
        elif kind == "fuselage":
            self.form = DataclassForm(ac.fuselage)
            v.addWidget(self.form)
        elif kind == "takeoff":
            self.form = DataclassForm(ac.takeoff, exclude=("VR", "de0", "rate_de", "rate_thr"))
            v.addWidget(self.form)
        elif kind == "airfield":
            self.form = DataclassForm(ac.airfield)
            v.addWidget(self.form)
        elif kind == "gear":
            self._gear_prev = ac.gear.layout
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
            v.addWidget(self._list_editor("eventos", ac.mission.events, MissionEvent, {"kind": EVENT_KINDS}))
        elif kind == "environment":
            # a densidade sai da altitude-densidade (atmosfera padrão): edita a AD, mostra o ρ
            self.form = DataclassForm(ac.environment, exclude=("rho",))
            v.addWidget(self.form)
            self._rho_info = QtWidgets.QLabel()
            self._rho_info.setStyleSheet("color: #555")
            v.addWidget(self._rho_info)
            self._show_rho()
        else:
            self.form = DataclassForm(getattr(ac, kind))
            v.addWidget(self.form)
        if self.form is not None:
            self.form.changed.connect(self._changed)
        v.addStretch(1)
        self.editor_area.setWidget(w)

    def _show_rho(self):
        env = self.state.aircraft.environment
        if getattr(self, "_rho_info", None) is not None:
            try:
                self._rho_info.setText(f"ρ = {env.rho:.4f} kg/m³ (atmosfera padrão na AD de {env.density_altitude:.0f} m)")
            except RuntimeError:          # o editor já foi trocado
                self._rho_info = None

    def _drop_editor(self):
        """onde soltar a carga: perna do percurso e distância dentro dela (evento 'drop')"""
        ac = self.state.aircraft
        box = QtWidgets.QGroupBox("Soltura (evento do percurso)")
        f = QtWidgets.QFormLayout(box)
        legs = QtWidgets.QComboBox()
        legs.addItems([f"{i}: {n}" for i, n in enumerate(ac.mission.names())])
        sx = NumberField("distância na perna", 0.0, 0, 1e5, 1.0, "m")
        ev = next((e for e in ac.mission.events if e.kind == "drop"), None)
        on = QtWidgets.QCheckBox("soltar a carga nesta missão")
        on.setChecked(ev is not None)
        if ev is not None:
            legs.setCurrentIndex(min(ev.leg, legs.count() - 1))
            sx.setValue(ev.s)

        def apply(*_):
            evs = [e for e in ac.mission.events if e.kind != "drop"]
            if on.isChecked():
                evs.append(MissionEvent("drop", max(legs.currentIndex(), 0), sx.value()))
            ac.mission.events = evs
            self.state.notify("geometry")
        on.toggled.connect(apply)
        legs.currentIndexChanged.connect(apply)
        sx.valueChanged.connect(apply)
        f.addRow(on)
        f.addRow("perna", legs)
        f.addRow(sx)
        return box

    def _sections_editor(self, s: LiftingSurface):
        box = QtWidgets.QGroupBox("Seções (raiz → ponta)")
        v = QtWidgets.QVBoxLayout(box)
        table = QtWidgets.QTableWidget(0, 5)
        table.setHorizontalHeaderLabels(["y (m)", "corda (m)", "recuo BA (m)", "torção (°)", "perfil"])
        table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        table.setMaximumHeight(170)
        table.setToolTip("perfil: cada seção pode ter o seu (entre seções as propriedades são interpoladas); "
                         "'= superfície' usa o perfil da superfície; digite um NACA ou carregue um .dat")
        SAME = "= superfície"
        LOAD = "carregar .dat…"

        def known() -> dict:
            """perfis já usados neste avião (nome → perfil), para escolher numa seção"""
            out = {}
            for t in self.state.aircraft.surfaces:
                for a in [t.airfoil] + [q.airfoil for q in t.sections if q.airfoil is not None]:
                    out.setdefault(a.name, a)
            return out

        def pick(r, text):
            sec = s.sections[r]
            if text == SAME:
                sec.airfoil = None
            elif text == LOAD:
                path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Perfil da seção", "", "Perfis (*.dat *.txt)")
                if not path:
                    fill()
                    return
                name, coords = read_dat(path)
                sec.airfoil = Airfoil(name, path=path, coords=coords.tolist())
            elif text.strip():
                k = known()
                sec.airfoil = copy.deepcopy(k[text]) if text in k else Airfoil(text.strip())
            fill()
            self.state.notify("geometry")

        def fill():
            table.blockSignals(True)
            table.setRowCount(len(s.sections))
            names = list(known())
            for r, sec in enumerate(s.sections):
                for c, a in enumerate(("y", "chord", "x_offset", "twist")):
                    table.setItem(r, c, QtWidgets.QTableWidgetItem(f"{getattr(sec, a):.4g}"))
                cb = QtWidgets.QComboBox()
                cb.setEditable(True)
                cb.addItems([SAME] + names + [LOAD])
                cb.setCurrentText(SAME if sec.airfoil is None else sec.airfoil.name)
                cb.textActivated.connect(lambda t, r=r: pick(r, t))
                table.setCellWidget(r, 4, cb)
            table.blockSignals(False)
            info.setText(f"S = {s.area:.4f} m²   b = {s.span:.3f} m   AR = {s.aspect_ratio:.2f}   c̄ = {s.mac:.3f} m")

        def edited(item):
            try:
                val = float(item.text().replace(",", "."))
            except ValueError:
                return
            if item.column() > 3:
                return
            setattr(s.sections[item.row()], ("y", "chord", "x_offset", "twist")[item.column()], val)
            fill()
            self.state.notify("geometry")

        def add():
            last = s.sections[-1] if s.sections else WingSection()
            s.sections.append(WingSection(last.y + 0.2, last.chord * 0.85, last.x_offset + 0.03, last.twist,
                                          copy.deepcopy(last.airfoil)))
            fill()
            self.state.notify("geometry")

        def rem():
            if len(s.sections) > 2:
                s.sections.pop(table.currentRow() if table.currentRow() >= 0 else -1)
                fill()
                self.state.notify("geometry")
        info = QtWidgets.QLabel()
        info.setWordWrap(True)
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

    def _list_editor(self, title, items: list, factory, choices: dict, editable: tuple = (), extra=None):
        """lista de dataclasses: um formulário por item, + / −; `extra(item)` acrescenta um widget ao item"""
        short, _, rest = title.partition(" — ")
        box = QtWidgets.QGroupBox(short)            # título curto: o grupo não força largura mínima
        v = QtWidgets.QVBoxLayout(box)
        if rest:
            note = QtWidgets.QLabel(rest)
            note.setWordWrap(True)
            note.setStyleSheet("color:#555")
            v.addWidget(note)
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
                f = DataclassForm(it, choices=choices, editable=editable)
                f.changed.connect(lambda *_: self.state.notify("geometry"))
                gl_.addWidget(f)
                if extra is not None:
                    gl_.addWidget(extra(it, f))
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
        box = self._list_editor("Comandos — o tipo é só o nome; o que o comando faz é a mistura (arfagem, rolagem, "
                                "guinada): elevon = 1, 1, 0; ruddervator = 1, 0, 1; flaperon = 0, 1, 0 com deflexão fixa",
                                s.controls, lambda: ControlSurface(default, 0.6, 1.0, 0.25), {"kind": CONTROL_KINDS},
                                editable=("kind",), extra=self._mix_row)
        if s.role == "wing" and any(c.kind == "aileron" for c in s.controls):
            b = QtWidgets.QPushButton("converter ailerons em elevons (asa voadora)")
            b.setToolTip("sem EH, o elevon faz arfagem e rolagem com a mesma superfície")

            def conv():
                for c in s.controls:
                    if c.kind == "aileron":
                        c.kind = "elevon"
                self.state.notify("geometry")
                self._edit(self._current_key())
            b.clicked.connect(conv)
            box.layout().addWidget(b)
        return box

    def _mix_row(self, c: ControlSurface, form) -> QtWidgets.QWidget:
        """a linha da mistura de um comando: ganho de arfagem, rolagem e guinada; mostra o que ele faz"""
        w = QtWidgets.QWidget()
        g = QtWidgets.QGridLayout(w)
        g.setContentsMargins(0, 0, 0, 0)
        what = QtWidgets.QLabel()
        what.setStyleSheet("color:#555")
        spins = []

        def show():
            names = {"elevator": "arfagem (profundor)", "aileron": "rolagem (aileron)", "rudder": "guinada (leme)",
                     "elevon": "arfagem + rolagem (elevon)", "ruddervator": "arfagem + guinada (cauda em V)",
                     "flap": "só deflexão fixa (flape)", "mixed": "rolagem + guinada"}
            what.setText("faz: " + names.get(c.role, c.role) + ("" if c.mix is not None else "  (do tipo)"))
            for sp, v in zip(spins, c.gains):
                sp.blockSignals(True)
                sp.setValue(v)
                sp.blockSignals(False)

        def edited(_=None):
            c.mix = [sp.value() for sp in spins]
            show()
            self.state.notify("geometry")
        for k, name in enumerate(("arfagem", "rolagem", "guinada")):
            sp = QtWidgets.QDoubleSpinBox()
            sp.setRange(-2.0, 2.0)
            sp.setSingleStep(0.1)
            sp.setDecimals(2)
            sp.setToolTip(f"ganho do canal de {name} neste comando (rolagem já é oposta nos dois lados)")
            sp.valueChanged.connect(edited)
            spins.append(sp)
            g.addWidget(QtWidgets.QLabel(name), 0, k)
            g.addWidget(sp, 1, k)
        g.addWidget(what, 2, 0, 1, 3)

        def kind_changed(field):
            if field == "kind" and c.kind in KIND_MIX:
                c.mix = None                             # escolheu um tipo conhecido: a mistura dele
                show()
                self.state.notify("geometry")
        form.changed.connect(kind_changed)
        show()
        return w

    def _devices_editor(self, s: LiftingSurface):
        """winglet, winglet para baixo, placa de ponta, cerca: geometria e posição livres"""
        box = self._list_editor("Dispositivos (winglet, placa de ponta, cerca…) — η: posição na semiasa, 1 = ponta",
                                s.devices, lambda: WingDevice("winglet", height=round(0.1 * max(s.span, 0.5), 3), enabled=False),
                                {"kind": DEVICE_KINDS})
        return box

    def _current_key(self) -> str:
        it = self.comp_list.currentItem()
        return it.data(QtCore.Qt.ItemDataRole.UserRole) if it is not None else "surface:0"

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
        box = QtWidgets.QGroupBox("Tração")
        v = QtWidgets.QVBoxLayout(box)
        model = QtWidgets.QComboBox()
        model.addItems(["motor + hélice (catálogo)", "polinômio de tração (conjunto)"])
        model.setCurrentIndex(1 if u.thrust_model == "poly" else 0)
        v.addWidget(model)
        holder = QtWidgets.QVBoxLayout()
        v.addLayout(holder)

        def fill():
            while holder.count():
                w = holder.takeAt(0).widget()
                if w:
                    w.deleteLater()
            holder.addWidget(self._poly_editor(u) if u.thrust_model == "poly" else self._motor_editor(u))

        def change(i):
            u.thrust_model = "poly" if i == 1 else "motor"
            fill()
            self.state.notify("geometry")
        model.currentIndexChanged.connect(change)
        bt = QtWidgets.QPushButton("Curva de tração × velocidade…")
        bt.clicked.connect(self._thrust_dialog)
        v.addWidget(bt)
        fill()
        return box

    def _poly_editor(self, u: PropulsionUnit):
        from aerosim.model.catalog import POLY_TERMS, POLY_VARS
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        sets = self.state.catalog.thrust_sets
        cb = QtWidgets.QComboBox()
        names = [t.name for t in sets]
        if u.thrust_poly.name not in names:
            names.insert(0, u.thrust_poly.name)
        cb.addItems(names)
        cb.setCurrentText(u.thrust_poly.name)
        lb = QtWidgets.QLabel(f"conjunto ({len(sets)} no catálogo)" + HELP_MARK)
        lb.setToolTip("importe a planilha (Arquivo → Importar catálogo) para trazer os conjuntos da aba Tracao")
        v.addWidget(lb)
        v.addWidget(cb)
        form_holder = QtWidgets.QVBoxLayout()
        v.addLayout(form_holder)
        table = QtWidgets.QTableWidget(len(POLY_TERMS), 1)
        table.setVerticalHeaderLabels(POLY_TERMS)
        table.setHorizontalHeaderLabels(["coeficiente"])
        table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        table.setMaximumHeight(200)
        v.addWidget(table)

        def fill():
            while form_holder.count():
                x = form_holder.takeAt(0).widget()
                if x:
                    x.deleteLater()
            f = DataclassForm(u.thrust_poly, exclude=("coefs", "name"), choices={"x_var": POLY_VARS, "y_var": POLY_VARS})
            f.changed.connect(lambda *_: self.state.notify("geometry"))
            form_holder.addWidget(f)
            table.blockSignals(True)
            for k in range(len(POLY_TERMS)):
                c = u.thrust_poly.coefs[k] if k < len(u.thrust_poly.coefs) else 0.0
                table.setItem(k, 0, QtWidgets.QTableWidgetItem(f"{c:.8g}"))
            table.blockSignals(False)

        def edited(item):
            try:
                val = float(item.text().replace(",", "."))
            except ValueError:
                return
            while len(u.thrust_poly.coefs) < len(POLY_TERMS):
                u.thrust_poly.coefs.append(0.0)
            u.thrust_poly.coefs[item.row()] = val
            self.state.notify("geometry")

        def pick(name):
            t = next((x for x in sets if x.name == name), None)
            if t is not None:
                u.thrust_poly = copy.deepcopy(t)
                fill()
                self.state.notify("geometry")
        cb.currentTextChanged.connect(pick)
        table.itemChanged.connect(edited)
        fill()
        return w

    def _motor_editor(self, u: PropulsionUnit):
        box = QtWidgets.QWidget()
        g = QtWidgets.QFormLayout(box)
        g.setContentsMargins(0, 0, 0, 0)
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
        from aerosim.model.templates import is_empty, not_ready
        msg = not_ready(ac)
        if msg:
            self.view.clear_markers()
            self.summary.setHtml(f"<h3 style='margin:0'>{escape(ac.name)}</h3><p style='color:#555'>"
                                 f"{escape(msg)}. Cada peça aparece no 3D assim que entra.</p>")
            self.info.setText(f"{ac.name}  —  " + ("vazio" if is_empty(ac) else "faltando massa"))
            return
        try:
            from aerosim.manager.calibration import static_characteristics
            info = static_characteristics(self.state.manager.backend, ac)
        except Exception as e:      # configuração inválida no meio da edição
            self.summary.setHtml(f"<span style='color:#b00'>{escape(str(e))}</span>")
            return
        cg = info["cg"]
        self.view.set_markers(cg=cg, np_x=info["x_np"])
        self.summary.setHtml(info_html(self.state.manager.backend, ac, info))
        self.info.setText(f"{ac.name}  —  {len(ac.surfaces)} superfícies, {len(ac.propulsion)} motores, "
                          f"{len(ac.tanks)} tanques")
        if self._tank_info is not None:
            try:
                key = self.comp_list.currentItem().data(QtCore.Qt.ItemDataRole.UserRole)
                t = ac.tanks[int(key.split(":")[1])]
                self._tank_info.setText(f"líquido: {t.liquid_mass:.3f} kg")
            except Exception:
                pass


def _tbl(title: str, rows: list[tuple[str, str]]) -> str:
    tr = "".join(f"<tr><td style='color:#444;padding-right:8px'>{escape(k)}</td><td><b>{v}</b></td></tr>"
                 for k, v in rows)
    return f"<h4 style='margin:10px 0 2px 0;color:#1f4e8c'>{escape(title)}</h4><table cellspacing=0>{tr}</table>"


def info_html(backend, ac, info) -> str:
    """painel da direita: tudo o que dá para saber da configuração sem simular"""
    from aerosim.model.features import features
    from aerosim.model.universal import build_model
    G = 9.80665
    model = build_model(ac)
    f = features(ac)
    S, c, b = model.S, model.c, model.b
    AR = b * b / S if S else float("nan")
    m, cg = info["mass"], info["cg"]
    sm = info["static_margin"] * 100
    warn = []
    out = [f"<h3 style='margin:0'>{escape(ac.name)}</h3><div style='color:#555'>{escape(f.summary())}</div>"]
    mp = None
    try:
        with backend.session_for(model) as s:
            mp = s.mass_props()
            units = [u for u in ac.propulsion if u.enabled]
            T0 = sum(s.prop_point(i, 0.0, 1.0)["T"] for i in range(len(units)))
    except Exception:
        units, T0 = [], float("nan")
    dry = model.mass["m"]
    liq = sum(t.liquid_mass for t in ac.tanks)
    pay = ac.payload.mass if ac.payload.enabled else 0.0
    rows = [("massa total", f"{m:.3f} kg"), ("aeronave seca", f"{dry:.3f} kg"), ("líquido nos tanques", f"{liq:.3f} kg"),
            ("carga LAPES", f"{pay:.3f} kg"),
            ("lastro", f"{ac.ballast.mass:.3f} kg em x = {ac.ballast.x:.3f} m" if ac.ballast.enabled else "—"),
            ("CG (x, y, z)", f"({cg[0]:.3f}, {cg[1]:.3f}, {cg[2]:.3f}) m"),
            ("CG em % da CMA", f"{100 * model.mac_frac(cg[0]):.1f} %")]
    if mp is not None and "I" in mp:
        I = np.asarray(mp["I"])
        rows.append(("Ixx, Iyy, Izz", f"{I[0, 0]:.3f}, {I[1, 1]:.3f}, {I[2, 2]:.3f} kg·m²"))
    out.append(_tbl("Massa e CG", rows))
    try:                                        # dimensões a partir do CG de projeto (ou do atual, sem projeto)
        from aerosim.design.dims import dimensions
        f = lambda v: "" if v is None else f"{v:+.3f}"
        drows = []
        if ac.design_cg is not None:
            d = [cg[k] - ac.design_cg[k] for k in range(3)]
            drows.append(("CG atual − CG de projeto", f"({d[0]:+.3f}, {d[1]:+.3f}, {d[2]:+.3f}) m"))
        for g, item, dx, dy, dz, val, note in dimensions(ac)[1:]:
            pos = f"({f(dx)}, {f(dy)}, {f(dz)})" if dx is not None else ""
            v = "" if val is None else f"{val:.3f}"
            drows.append((item, f"{pos} {('= ' + v) if v else ''}".strip()))
        title = "Dimensões a partir do CG de projeto" if ac.design_cg is not None else "Dimensões a partir do CG atual"
        out.append(_tbl(title + " (Δx, Δy, Δz) m", drows))
    except Exception:
        pass
    cor = "#080" if 5 <= sm <= 30 else "#b00"
    if not 5 <= sm <= 30:
        warn.append(f"margem estática {sm:.1f} % fora de 5–30 %")
    rows = [("S, b, AR", f"{S:.3f} m², {b:.2f} m, {AR:.2f}"), ("CMA (c̄)", f"{c:.3f} m"),
            ("C_L0, C_Lα", f"{info['CL0']:.3f}, {info['CLa']:.2f} /rad"),
            ("C_Lmax (α de estol)", f"{info['CLmax']:.2f} ({info['alpha_stall']:.1f}°)"),
            ("margem estática", f"<span style='color:{cor}'>{sm:.1f} %</span>"),
            ("ponto neutro x_NP", f"{info['x_np']:.3f} m"), ("V de estol", f"{info['Vs']:.2f} m/s")]
    try:
        tv = model.tail_volumes(cg[0])
        if tv["Sh"] > 0:
            rows.append(("volume de cauda horizontal V_H", f"{tv['VH']:.3f} (braço {tv['lh']:.2f} m)"))
        if tv["Sv"] > 0:
            rows.append(("volume de cauda vertical V_V", f"{tv['VV']:.4f} (braço {tv['lv']:.2f} m)"))
    except Exception:
        pass
    out.append(_tbl("Aerodinâmica (núcleo)", rows))
    W = m * G
    rows = [("carga alar W/S", f"{W / S:.1f} N/m² ({m / S:.2f} kg/m²)"),
            ("tração estática total", f"{T0:.1f} N"), ("T/W estático", f"{T0 / W:.3f}" if W else "—")]
    out.append(_tbl("Cargas", rows))
    if T0 / W < 0.25:
        warn.append(f"T/W estático baixo ({T0 / W:.2f})")
    rows = []
    for u in units:
        bt = u.battery
        rows.append((u.name, (f"polinômio '{escape(u.thrust_poly.name)}'" if u.thrust_model == "poly" else
                              f"{u.motor.Kv:.0f} Kv, hélice {u.propeller.D * 39.37:.1f}\"") +
                     f"; bateria {bt.cells}S {bt.capacity_mAh:.0f} mAh ({bt.Voc * bt.capacity_mAh / 1000:.0f} Wh)"))
    if rows:
        out.append(_tbl("Propulsão", rows))
    g = ac.gear
    legs = g.legs()
    mains = [q for q in legs if q.kind == "main"]
    steer = [q for q in legs if q.kind == "steer"]
    rows = [("tipo", g.layout)]
    if mains and steer:
        rows.append(("distância entre eixos", f"{abs(steer[0].x - mains[0].x):.3f} m"))
        if g.layout == "tricycle":
            frac = (steer[0].x - cg[0]) / (steer[0].x - mains[0].x) if steer[0].x != mains[0].x else float("nan")
            rows.append(("peso na bequilha (estático)", f"{100 * (1 - frac):.1f} %"))
            if not 0.05 <= 1 - frac <= 0.25:
                warn.append(f"peso na bequilha {100 * (1 - frac):.0f} % (usual 5–20 %)")
    if len(mains) >= 2:
        rows.append(("bitola", f"{abs(mains[0].y - mains[-1].y):.3f} m"))
    skids = [q for q in legs if q.kind == "skid"]
    if mains and skids and mains[0].x > skids[0].x:
        rows.append(("θ que encosta a cauda", f"{math.degrees(math.atan2(mains[0].z - skids[0].z, mains[0].x - skids[0].x)):.1f}°"))
    out.append(_tbl("Trem de pouso", rows))
    af = ac.airfield
    rows = [("decolagem", "do chão" if af.takeoff_from == "chão" else
             f"de uma mesa de {af.table_height:g} m de altura, {af.table_length:g} m à frente"),
            ("pouso", "no chão" if af.landing_on == "chão" else
             f"numa plataforma de {af.platform_height:g} m × {af.platform_length:g} m"),
            ("comprimento de pista exigido (x_warning)", f"{af.x_warning:g} m"),
            ("altura mínima (z_warning)", f"{af.z_warning:g} m")]
    if af.landing_max > 0:
        rows.append(("distância máxima de pouso", f"{af.landing_max:g} m"))
    out.append(_tbl("Pista", rows))
    P = ac.payload
    drop = next((e for e in ac.mission.events if e.kind == "drop"), None)
    if P.enabled:
        rows = [("massa", f"{P.mass:.2f} kg"), ("posição", f"({P.x:.3f}, {P.y:.3f}, {P.z:.3f}) m"),
                ("soltura", f"perna {drop.leg} ({escape(ac.mission.names()[drop.leg]) if drop.leg < len(ac.mission.legs) else '?'}), "
                 f"s = {drop.s:.0f} m" if drop else "sem evento de soltura"),
                ("alvo", f"n = {P.target_n:g} m, e = {P.target_e:g} m" + (" (procura o ponto)" if P.aim else ""))]
        out.append(_tbl("LAPES", rows))
    segs = ac.mission.segments()
    out.append(_tbl("Percurso", [("pernas", str(len(segs))), ("comprimento", f"{sum(q['L'] for q in segs):.0f} m"),
                                 ("altura máx.", f"{max((q['h1'] for q in segs), default=0):.0f} m")]))
    if warn:
        out.append("<h4 style='color:#b00;margin:10px 0 2px 0'>Avisos</h4><ul style='margin:0'>" +
                   "".join(f"<li>{escape(w)}</li>" for w in warn) + "</ul>")
    return "".join(out)
