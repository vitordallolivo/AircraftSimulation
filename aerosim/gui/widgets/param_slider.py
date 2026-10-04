"""Slider + campo numérico sincronizados, e um formulário automático para dataclasses."""
from __future__ import annotations

import dataclasses
import typing

from PyQt6 import QtCore, QtWidgets

# faixas dos sliders por nome de campo: (mín, máx, passo, unidade)
RANGES: dict[str, tuple[float, float, float, str]] = {
    "x": (-2.5, 2.5, 0.005, "m"), "y": (-2.5, 2.5, 0.005, "m"), "z": (-1.0, 1.0, 0.005, "m"),
    "x_nose": (-1.0, 2.5, 0.005, "m"), "x_start": (-2.0, 1.0, 0.005, "m"), "length": (0.05, 3.0, 0.005, "m"),
    "width": (0.02, 1.0, 0.005, "m"), "height": (0.02, 1.0, 0.005, "m"), "diameter": (0.005, 0.2, 0.001, "m"),
    "dihedral": (-45, 60, 0.5, "°"), "incidence": (-10, 10, 0.1, "°"), "tilt": (-20, 20, 0.5, "°"),
    "toe": (-20, 20, 0.5, "°"), "oswald": (0.3, 1.0, 0.01, ""), "eta": (0.3, 1.2, 0.01, ""),
    "mass": (0.0, 20.0, 0.01, "kg"), "base_mass": (0.1, 50.0, 0.01, "kg"),
    "Ixx": (0.0, 10.0, 0.01, "kg m²"), "Iyy": (0.0, 10.0, 0.01, "kg m²"), "Izz": (0.0, 10.0, 0.01, "kg m²"),
    "Ixz": (-2.0, 2.0, 0.005, "kg m²"), "side": (0.02, 0.5, 0.002, "m"), "fill": (0.0, 0.5, 0.002, "m"),
    "rho": (0.5, 1500.0, 1.0, "kg/m³"), "zeta": (0.0, 0.5, 0.005, ""), "bay": (0.05, 1.0, 0.01, "m"),
    "main_x": (-1.0, 1.0, 0.005, "m"), "main_track": (0.05, 2.0, 0.005, "m"), "main_z": (0.01, 0.6, 0.002, "m"),
    "steer_x": (-2.5, 2.0, 0.005, "m"), "steer_z": (0.0, 0.6, 0.002, "m"), "skid_x": (-2.5, 0.0, 0.005, "m"),
    "skid_z": (-0.2, 0.4, 0.002, "m"), "yaw_mix": (-1.0, 1.0, 0.01, ""), "chord": (0.02, 2.0, 0.005, "m"),
    "x_offset": (-1.0, 2.0, 0.005, "m"), "twist": (-15, 15, 0.1, "°"), "span_start": (0.0, 1.0, 0.01, ""),
    "span_end": (0.0, 1.0, 0.01, ""), "chord_frac": (0.05, 0.6, 0.01, ""), "deflection": (-40, 40, 0.5, "°"),
    "cl_alpha": (2.0, 7.0, 0.05, "1/rad"), "cl_max": (0.5, 2.5, 0.01, ""), "cd0": (0.0, 0.1, 0.001, ""),
    "wind_speed": (0.0, 20.0, 0.1, "m/s"), "wind_from": (-180, 180, 1, "°"), "wind_elev": (-20, 20, 0.5, "°"),
    "density_altitude": (-500, 4000, 10, "m"), "alpha_cruise": (-5, 15, 0.1, "°"), "load_factor": (1.0, 6.0, 0.1, ""),
    "ceiling_min": (0, 5000, 10, "m"), "rho0": (0.5, 1.5, 0.005, "kg/m³"),
    "VR": (0.0, 40.0, 0.1, "m/s"), "sR": (0.0, 200.0, 0.5, "m"), "de0": (-25, 25, 0.5, "°"),
    "de1": (-25, 25, 0.5, "°"), "ht": (0.5, 20, 0.1, "m"), "h_end": (1, 50, 0.5, "m"),
    "alpha_max": (2, 25, 0.5, "°"), "phimax": (5, 80, 1, "°"), "dt": (1e-4, 1e-2, 1e-4, "s"),
    "tmax": (5, 2000, 5, "s"), "dtlog": (1e-3, 0.5, 1e-3, "s"), "CDS": (0.0, 0.2, 0.001, "m²"),
}


def _decimals(step: float) -> int:
    s = f"{step:.10f}".rstrip("0")
    return max(0, len(s.split(".")[1]) if "." in s else 0)


class ParamSlider(QtWidgets.QWidget):
    """rótulo | slider | campo — arrastar ou digitar"""
    valueChanged = QtCore.pyqtSignal(float)
    RES = 1000

    def __init__(self, label: str, value: float, minimum: float = 0.0, maximum: float = 1.0, step: float = 0.01,
                 unit: str = "", parent=None):
        super().__init__(parent)
        self._lo, self._hi = minimum, maximum
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.label = QtWidgets.QLabel(label)
        self.label.setMinimumWidth(90)
        self.label.setToolTip(label)
        self.slider = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal)
        self.slider.setRange(0, self.RES)
        self.spin = QtWidgets.QDoubleSpinBox()
        self.spin.setDecimals(min(_decimals(step) + 1, 6))
        self.spin.setRange(minimum, maximum)
        self.spin.setSingleStep(step)
        self.spin.setSuffix(f" {unit}" if unit else "")
        self.spin.setKeyboardTracking(False)
        self.spin.setMinimumWidth(92)
        lay.addWidget(self.label, 3)
        lay.addWidget(self.slider, 4)
        lay.addWidget(self.spin, 3)
        self._block = False
        self.setValue(value)
        self.slider.valueChanged.connect(self._from_slider)
        self.spin.valueChanged.connect(self._from_spin)

    def value(self) -> float:
        return self.spin.value()

    def setValue(self, v: float) -> None:
        self._block = True
        if v < self._lo:
            self._lo = v
        if v > self._hi:
            self._hi = v
        self.spin.setValue(v)
        self.slider.setValue(self._to_pos(v))
        self._block = False

    def _to_pos(self, v):
        span = self._hi - self._lo
        return int(round((v - self._lo) / span * self.RES)) if span > 0 else 0

    def _from_slider(self, pos):
        if self._block:
            return
        v = self._lo + (self._hi - self._lo) * pos / self.RES
        self._block = True
        self.spin.setValue(v)
        self._block = False
        self.valueChanged.emit(self.spin.value())

    def _from_spin(self, v):
        if self._block:
            return
        self._block = True
        if v < self._lo or v > self._hi:
            self._lo, self._hi = min(self._lo, v), max(self._hi, v)
        self.slider.setValue(self._to_pos(v))
        self._block = False
        self.valueChanged.emit(v)


class NumberField(QtWidgets.QWidget):
    """rótulo | campo numérico (digitar, setas ou roda do mouse com o campo em foco) — sem slider"""
    valueChanged = QtCore.pyqtSignal(float)

    def __init__(self, label: str, value: float, minimum: float = -1e9, maximum: float = 1e9, step: float = 0.01,
                 unit: str = "", parent=None):
        super().__init__(parent)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.label = QtWidgets.QLabel(label)
        self.label.setWordWrap(True)
        self.label.setToolTip(label)
        self.spin = _Spin()
        self.spin.setMinimumWidth(105)
        self.spin.setDecimals(min(_decimals(step) + 1, 6))
        self.spin.setRange(-1e9, 1e9)
        self.spin.setSingleStep(step)
        self.spin.setSuffix(f" {unit}" if unit else "")
        self.spin.setKeyboardTracking(False)
        self.spin.setValue(value)
        lay.addWidget(self.label, 5)
        lay.addWidget(self.spin, 4)
        self.spin.valueChanged.connect(self.valueChanged.emit)

    def value(self) -> float:
        return self.spin.value()

    def setValue(self, v: float) -> None:
        self.spin.blockSignals(True)
        self.spin.setValue(v)
        self.spin.blockSignals(False)


class _Spin(QtWidgets.QDoubleSpinBox):
    """não rouba a roda do mouse da rolagem do painel: só muda o valor se estiver em foco"""

    def __init__(self):
        super().__init__()
        self.setFocusPolicy(QtCore.Qt.FocusPolicy.StrongFocus)

    def wheelEvent(self, e):
        if self.hasFocus():
            super().wheelEvent(e)
        else:
            e.ignore()


CHOICES = {
    "role": ("wing", "htail", "vtail"),
    "kind": None,      # depende do contexto (ver DataclassForm.choices)
    "layout": ("tricycle", "conventional", "custom"),
    "shape": ("square", "cylinder"),
    "takeoff_from": ("chão", "mesa"),
    "landing_on": ("chão", "plataforma"),
}
CONTROL_KINDS = ("aileron", "elevator", "rudder", "elevon", "ruddervator", "flap")
GEAR_KINDS = ("steer", "main", "skid")
LEG_KINDS = ("straight", "turn")
EVENT_KINDS = ("drop", "gust")

LABELS = {
    "x": "x", "y": "y", "z": "z", "name": "nome", "role": "papel", "dihedral": "diedro", "incidence": "incidência",
    "symmetric": "simétrica", "vertical": "vertical", "oswald": "Oswald e", "eta": "η (q local)",
    "downwash": "sente downwash", "enabled": "ativo", "mass": "massa", "tilt": "inclinação do eixo",
    "toe": "desvio do eixo", "sense": "sentido (±1)", "yaw_mix": "acel. diferencial", "side": "lado/diâmetro",
    "fill": "altura do líquido", "height": "altura", "zeta": "amortecimento",
    "shape": "forma", "layout": "tipo", "main_x": "principal x", "main_track": "bitola", "main_z": "principal z",
    "steer_x": "direcionável x", "steer_z": "direcionável z", "tail_skid": "patim de cauda", "skid_x": "patim x",
    "skid_z": "patim z", "x_nose": "nariz x", "length": "comprimento", "width": "largura",
    "x_start": "início x", "diameter": "diâmetro", "attach_tail": "cauda na ponta", "bay": "baia",
    "span_start": "início (fração)", "span_end": "fim (fração)", "chord_frac": "corda (fração)",
    "deflection": "deflexão fixa", "chord": "corda", "x_offset": "recuo do BA", "twist": "torção",
    "takeoff_from": "decola de", "table_height": "altura da mesa", "table_length": "mesa à frente da partida",
    "table_back": "mesa atrás da partida", "table_width": "largura da mesa", "landing_on": "pousa em",
    "platform_height": "altura da plataforma", "platform_length": "comprimento da plataforma",
    "platform_width": "largura da plataforma", "h_end": "altura final da decolagem",
    "mu_b": "atrito na baia", "CdS_chute": "C_D·S do paraquedas",
    "target_n": "alvo: norte", "target_e": "alvo: leste",
    "density_altitude": "altitude-densidade (AD)", "alpha_cruise": "ângulo de cruzeiro",
    "load_factor": "fator de carga de projeto", "ceiling_min": "teto mínimo", "rho0": "densidade de referência",
    "cdp_x": "C_Dp: multiplicador", "cdp_wing": "C_Dp da asa (c1, c2)", "cdp_htail": "C_Dp do EH (c1, c2)",
    "K": "C_Di = K C_L² (vazio: 1/(π e AR))",
    "wind_speed": "vento a 10 m", "wind_from": "vento vem de", "wind_elev": "elevação do vento",
    "gust": "rajada", "slosh": "sloshing", "auto_calibrate": "calibrar antes de voar",
    "x_warning": "x_warning (pista)", "z_warning": "z_warning (altura)", "sR": "acionamento do profundor",
    "de1": "deflexão de decolagem", "ht": "piloto assume em", "platform_start": "plataforma: início antes do fim",
    "landing_max": "distância máx. de pouso", "aim": "mirar no alvo", "Fext_g": "paraquedas extrator",
    "volume": "volume de líquido", "rho": "densidade do líquido",
    "airfoil": "perfil", "path": "arquivo .dat", "cl_alpha": "a1 (inclinação 2D)", "alpha0": "α de sustentação nula",
    "cl_max": "c_l,max", "cd0": "c_d mín.", "cm_ac": "c_m,ac",
}
# dicas (passe o mouse no ⓘ): o rótulo fica curto, a explicação vai aqui
HELP = {
    "x_warning": "comprimento de pista: tem de passar do z_warning antes desta distância",
    "z_warning": "altura sobre a superfície de partida que conta como decolado; ≤ 0 na mesa: quanto pode afundar",
    "sR": "distância na pista em que o profundor (ou elevon) vai para a deflexão de decolagem; a Missão otimiza",
    "de1": "deflexão do profundor na rotação (negativo = cabra); a Missão usa a maior que funciona",
    "ht": "abaixo desta altura o profundor fica na deflexão de decolagem; acima, o piloto automático assume",
    "h_end": "altura em que a etapa de decolagem termina",
    "platform_start": "a plataforma começa este tanto antes do fim da última perna (pouso)",
    "landing_max": "do toque até parar; 0 = não verifica",
    "aim": "na Missão, procura o ponto de soltura para a carga cair no alvo",
    "Fext_g": "força do paraquedas extrator, em vezes o peso da carga",
    "mu_b": "atrito da carga deslizando na baia",
    "CdS_chute": "área de arrasto do paraquedas da carga",
    "bay": "comprimento da baia por onde a carga desliza",
    "eta": "pressão dinâmica local / a do voo livre (cauda na esteira < 1)",
    "oswald": "eficiência de envergadura (arrasto induzido)",
    "downwash": "a superfície sente o downwash da asa (cauda atrás da asa)",
    "yaw_mix": "diferença de acelerador entre motores para ajudar a guinada",
    "sense": "+1 ou −1: sentido de rotação da hélice (torque)",
    "zeta": "amortecimento do líquido (sloshing)",
    "volume": "litros de líquido no tanque",
    "rho": "densidade: água 1000 kg/m³",
    "layout": "triciclo: bequilha na frente; convencional: bequilha na cauda; custom: pernas livres",
    "tail_skid": "patim que protege a cauda na rotação",
    "attach_tail": "a cauda fica presa na ponta do tubo",
    "wind_from": "0 = de frente (norte), 90 = da direita (leste)",
    "density_altitude": "altitude da atmosfera padrão com a densidade do ar do dia; dela sai ρ",
    "alpha_cruise": "ângulo de ataque de cruzeiro usado no envelope de voo",
    "load_factor": "n de projeto do envelope: V* = V_e √n",
    "wind_elev": "inclinação do vento (+ sobe)",
    "gust": "rajada no evento 'gust' do percurso",
    "slosh": "o líquido dos tanques mexe e empurra a aeronave",
    "auto_calibrate": "recalcula C_L0, C_Lα e acelerador de trimagem antes de cada voo",
    "CL0": "modelo do piloto: C_L em α = 0", "CLa": "modelo do piloto: inclinação de C_L (1/rad)",
    "alpha_max": "o piloto não pede α acima disto", "g_up": "subida máx. (fração de V)",
    "g_down": "descida máx. (fração de V)", "Khr": "ganho altura → razão de subida",
    "Kvs": "corta a subida quando falta velocidade", "Kn_h": "ganho do erro de altura no fator de carga",
    "Kn_hd": "ganho do erro de razão de subida", "Kn_ih": "integral do erro de altura",
    "Kae": "profundor: ganho do erro de α", "KIa": "profundor: integral", "Kqe": "profundor: amortecimento de q",
    "Kthe": "profundor no chão: ganho de θ", "Kfn": "arredondamento: ganho de ḣ",
    "KV": "acelerador: erro de V", "KIV": "acelerador: integral de V", "KHT": "acelerador: erro de altura",
    "Dtrim": "acelerador de equilíbrio (calibrado)", "Kchi": "curso → inclinação",
    "kvf": "reta: quanto corrige o desvio lateral", "chi_inf": "reta: ângulo máx. de aproximação da linha",
    "korb": "curva: quanto corrige o desvio do raio", "Lorb": "curva: escala do desvio (m)",
    "tlead": "antecipa a próxima perna (s)", "phimax": "inclinação máx. que o piloto usa",
    "Kphia": "aileron: erro de φ", "Kpa": "aileron: amortecimento de p", "Kbeta": "leme: ganho do derrapagem β",
    "tau_phi": "atraso do comando de φ (s)", "pmax_cmd": "taxa máx. do comando de φ (°/s)",
    "Ky": "chão: desvio lateral → proa", "Ki": "chão: integral do desvio", "Kpsi": "chão: erro de proa",
    "Kr": "chão: amortecimento de r", "Kbeq": "chão: bequilha", "hflare": "altura do arredondamento",
    "tau_flare": "constante do arredondamento (s)", "kCL": "limite de C_L/C_Lmax usado nas verificações",
    "de_max": "deflexão máx. do profundor", "da_max": "deflexão máx. do aileron", "dr_max": "deflexão máx. do leme",
    "Mst": "suavidade da transição para o estol", "dtlog": "intervalo de gravação", "tmax": "tempo máx. de voo",
    "dt": "passo de integração",
}
HELP_MARK = " <span style='color:#1f77b4'>ⓘ</span>"

UNITS = {"table_height": "m", "table_length": "m", "table_back": "m", "table_width": "m", "platform_height": "m",
         "platform_length": "m", "platform_width": "m", "platform_start": "m", "x_warning": "m", "z_warning": "m", "landing_max": "m",
         "target_n": "m", "target_e": "m", "CdS_chute": "m²"}


def _hint(w, text: str) -> None:
    """ⓘ no rótulo, explicação no passar do mouse"""
    w.setToolTip(text)
    if isinstance(w, QtWidgets.QCheckBox):
        w.setText(w.text() + " ⓘ")
        return
    lb = getattr(w, "label", None) or w.findChild(QtWidgets.QLabel)
    if lb is not None:
        lb.setTextFormat(QtCore.Qt.TextFormat.RichText)
        lb.setText(lb.text() + HELP_MARK)
        lb.setToolTip(text)


class DataclassForm(QtWidgets.QWidget):
    """formulário gerado a partir dos campos de uma dataclass (edita o objeto no lugar)"""
    changed = QtCore.pyqtSignal(str)

    def __init__(self, obj, exclude: tuple = (), choices: dict | None = None, parent=None, editable: tuple = ()):
        """rótulo, unidade, dica, opções e passo vêm dos metadados do campo (`aerosim.design.fields.F`) ou,
        sem eles, dos dicionários deste módulo; `choices` (por campo) manda sobre os dois; em `editable` a
        lista de opções aceita texto livre"""
        super().__init__(parent)
        self.obj = obj
        self.choices = dict(CHOICES)
        self.choices.update(choices or {})
        self._given = dict(choices or {})
        self._editable = set(editable)
        self.widgets: dict[str, QtWidgets.QWidget] = {}
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        hints = typing.get_type_hints(type(obj))
        for f in dataclasses.fields(obj):
            if f.name in exclude:
                continue
            tp = hints[f.name]
            v = getattr(obj, f.name)
            meta = dict(f.metadata)
            w = self._make(f.name, tp, v, meta)
            if w is not None:
                tip = meta.get("help") or HELP.get(f.name)
                if tip:
                    _hint(w, tip)
                lay.addWidget(w)
                self.widgets[f.name] = w

    def _make(self, name, tp, v, meta=None):
        meta = meta or {}
        label = meta.get("label") or LABELS.get(name, name)
        opt = typing.get_origin(tp) in (typing.Union, getattr(__import__("types"), "UnionType", None))
        base = [a for a in typing.get_args(tp) if a is not type(None)][0] if opt else tp
        if dataclasses.is_dataclass(base):
            box = QtWidgets.QGroupBox(label)
            inner = DataclassForm(v, exclude=("coords",), choices=self._given)
            inner.changed.connect(lambda k, n=name: self.changed.emit(f"{n}.{k}"))
            QtWidgets.QVBoxLayout(box).addWidget(inner)
            return box
        if base is bool:
            w = QtWidgets.QCheckBox(label)
            w.setChecked(bool(v))
            w.toggled.connect(lambda val, n=name: self._set(n, bool(val)))
            return w
        if base is str:
            ch = self._given.get(name) or meta.get("choices") or self.choices.get(name)
            if ch:
                w = QtWidgets.QComboBox()
                w.addItems(list(ch))
                if name in self._editable:
                    w.setEditable(True)
                    w.setCurrentText(v)
                elif v in ch:
                    w.setCurrentText(v)
                w.currentTextChanged.connect(lambda val, n=name: self._set(n, val))
            else:
                w = QtWidgets.QLineEdit(v)
                w.editingFinished.connect(lambda n=name, ww=w: self._set(n, ww.text()))
            return self._row(label, w)
        if base is int:
            w = QtWidgets.QSpinBox()
            w.setRange(-1000000, 1000000)
            w.setValue(int(v))
            w.valueChanged.connect(lambda val, n=name: self._set(n, int(val)))
            return self._row(label, w)
        if base is float:
            if opt:      # sobrescrita opcional: caixa "auto" + campo
                return self._optional(name, label, v)
            lo, hi, st, un = RANGES.get(name, (min(0.0, v * 2) if v else -1.0, max(1.0, v * 2) if v else 1.0, 0.01,
                                               UNITS.get(name, "")))
            mn, mx = -1e9, 1e9
            if "range" in meta:
                r0, r1, r2 = meta["range"]
                mn, mx, st = (r0 if r0 is not None else mn), (r1 if r1 is not None else mx), (r2 or st)
            if "label" in meta:
                un = meta.get("unit", "")
            w = NumberField(label, float(v), minimum=mn, maximum=mx, step=st, unit=un)
            w.valueChanged.connect(lambda val, n=name: self._set(n, float(val)))
            return w
        return None          # listas: editores próprios

    def _optional(self, name, label, v):
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        auto = QtWidgets.QCheckBox(f"{label}: auto")
        spin = QtWidgets.QDoubleSpinBox()
        spin.setMinimumWidth(105)
        spin.setDecimals(5)
        spin.setRange(-1e6, 1e6)
        spin.setSingleStep(0.01)
        auto.setChecked(v is None)
        spin.setEnabled(v is not None)
        spin.setValue(0.0 if v is None else float(v))
        auto.toggled.connect(lambda on: (spin.setEnabled(not on), self._set(name, None if on else spin.value())))
        spin.valueChanged.connect(lambda val: self._set(name, float(val)) if not auto.isChecked() else None)
        h.addWidget(auto, 3)
        h.addWidget(spin, 2)
        return box

    def _row(self, label, w):
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        lb = QtWidgets.QLabel(label)
        lb.setWordWrap(True)
        w.setMinimumWidth(105)
        h.addWidget(lb, 4)
        h.addWidget(w, 6)
        return box

    def _set(self, name, value):
        setattr(self.obj, name, value)
        self.changed.emit(name)

    def refresh(self) -> None:
        """relê os valores do objeto (depois de um arraste no 3D, por exemplo)"""
        for name, w in self.widgets.items():
            v = getattr(self.obj, name)
            if isinstance(w, (ParamSlider, NumberField)) and isinstance(v, (int, float)):
                w.setValue(float(v))
