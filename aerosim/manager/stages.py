"""As etapas da sprint sem Qt, para a tela em Zig pela ponte (`aerosim/bridge.py`): o mesmo que as páginas de
`aerosim/gui/design/pages.py` fazem (o rascunho, as escolhas, os guardados, a conta e o "guardar"), chamando as
mesmas funções de `aerosim.design`. A tela desenha o formulário a partir de `form()` e mostra o que `compute()`
devolve (gráficos, diagnóstico, resumo e tabelas).

    perfis       Aerodinâmica → Perfis           candidatos e a polar 2D de cada um
    asa          Aerodinâmica → Projetar         a asa a partir do perfil escolhido
    empenagem    Estabilidade → Empenagem        cauda, tubo e comandos para a asa guardada
    motores      Desempenho → Motores            motores, massas, trem → o avião inteiro
    requisitos   "Condições e restrições…"       condições e regras do projeto (as das etapas)

O projeto (`DesignProject`) fica numa pasta (a mesma "sprint" da GUI PyQt) e é gravado a cada mudança.
"""
from __future__ import annotations

import copy
import os
from dataclasses import dataclass, field
from typing import Any

from aerosim.design import airfoils as afm
from aerosim.design import registry as rg
from aerosim.design import results as R
from aerosim.design import wing as wg
from aerosim.interfaces.simulation import ParamSpec, PlotSpec, SimResult
from aerosim.model.aircraft import Aircraft

from . import forms

TAIL_AIRFOILS = ("NACA 0012", "NACA 0010", "NACA 0009", "NACA 0008")
DIMS_HEAD = ("grupo", "item", "Δx (m)", "Δy (m)", "Δz (m)", "valor")


@dataclass
class Action:
    """um botão da etapa: `arg` diz o que a tela pede antes ("" nada, "text" um texto, "file" um arquivo)"""
    key: str
    label: str
    arg: str = ""
    help: str = ""
    default: str = ""


@dataclass
class Table:
    """uma tabela de números para a tela (massas, dimensões)"""
    title: str
    headers: tuple
    rows: list


@dataclass
class Outcome:
    """o que uma etapa mostra depois da conta"""
    plots: list[PlotSpec] = field(default_factory=list)
    result: SimResult = field(default_factory=SimResult)
    tables: list[Table] = field(default_factory=list)
    message: str = ""
    aircraft: Aircraft | None = None
    markers: dict = field(default_factory=dict)    # no 3D: cg=[x, y, z] e np_x (ponto neutro), como a GUI PyQt


@dataclass
class GridColumn:
    """uma coluna de tabela editável: o campo, o título, o tipo ("float" ou "choice") e as opções"""
    key: str
    label: str
    kind: str = "float"
    choices: tuple = ()
    help: str = ""


@dataclass
class Grid:
    """uma tabela que se edita no lugar (as partições da asa), com os botões dela; `rows`: os valores por linha"""
    name: str
    title: str
    columns: list
    rows: list
    note: str = ""
    help: str = ""
    buttons: list = field(default_factory=list)      # [(op, rótulo, dica)]


@dataclass
class Context:
    """o que as etapas dividem: o projeto, o catálogo, o núcleo e onde se guarda"""
    design: Any
    catalog: Any
    backend: Any
    projects: Any = None
    folder: str = ""
    values: dict = field(default_factory=dict)      # as grandezas da última etapa que rodou (restrições)

    def save(self) -> None:
        if self.folder:
            from aerosim.design import store
            store.save(self.design, self.folder)


def _drop(items: list, item) -> None:
    """tira `item` da lista por identidade (dois dispositivos iguais são objetos diferentes)"""
    items[:] = [x for x in items if x is not item]


def only_surfaces(surfaces, boom=None) -> Aircraft:
    """um 'avião' só com as peças da etapa (para o 3D e as dimensões)"""
    ac = Aircraft(name="prévia", surfaces=copy.deepcopy(surfaces))
    ac.fuselage.enabled = False
    ac.gear.layout = "custom"
    ac.propulsion = []
    ac.tanks = []
    ac.payload.enabled = False
    if boom is not None:
        ac.boom = copy.deepcopy(boom)
    return ac


def dims_table(ac, cg=None) -> Table:
    from aerosim.design.dims import dimensions
    try:
        rows = dimensions(ac, cg)
    except Exception as error:          # avião incompleto: mostra o que der, como a GUI PyQt
        rows = [("—", f"não deu para medir: {error}", None, None, None, None, "")]
    text = lambda v: "" if v is None else f"{v:+.3f}"
    return Table("Dimensões a partir do CG de projeto", DIMS_HEAD,
                 [[g, item, text(dx), text(dy), text(dz), "" if val is None else f"{val:.3f}"]
                  for g, item, dx, dy, dz, val, _ in rows])


class Stage:
    name = ""
    title = ""
    help = ""
    keep_label = "Guardar"

    def __init__(self, ctx: Context):
        self.ctx = ctx

    # o que cada etapa define (os mesmos nomes de `StagePage`)
    def draft(self):
        raise NotImplementedError

    def set_draft(self, params) -> None:
        raise NotImplementedError

    def choices(self) -> dict:
        return {}

    def editable(self) -> tuple:
        return ()

    def exclude(self) -> tuple:
        return ()

    def kept_items(self) -> list:
        return []

    def compute(self) -> Outcome | None:
        raise NotImplementedError

    def keep(self) -> str | None:
        raise NotImplementedError

    def actions(self) -> list[Action]:
        return []

    def act(self, key: str, arg: str) -> str:
        raise KeyError(key)

    def disabled(self) -> tuple:
        """campos que aparecem em cinza (o modo atual calcula eles)"""
        return ()

    def grids(self) -> list[Grid]:
        """as tabelas editáveis da etapa (as partições da asa)"""
        return []

    def edit_grid(self, name: str, op: str, row: int, key: str = "", value: Any = None) -> None:
        """uma edição numa tabela: "set" (a célula `key` da linha `row`) ou um botão dela"""
        raise KeyError(name)

    # comum
    def sanitize(self) -> None:
        """escolhas que não existem mais viram a primeira disponível (como `StagePage.sanitize`)"""
        d = self.draft()
        if d is None:
            return
        for k, opts in self.choices().items():
            if opts and k not in self.editable() and getattr(d, k) not in opts:
                setattr(d, k, opts[0] if k not in ("set", "wing") else opts[-1])

    def form(self) -> list[ParamSpec]:
        self.sanitize()
        d = self.draft()
        return [] if d is None else forms.specs(d, exclude=self.exclude(), choices=self.choices(),
                                                editable=self.editable())

    def set(self, values: dict) -> list[str]:
        d = self.draft()
        changed = [] if d is None else forms.apply(d, values)
        if changed:
            self.after_edit(changed)
            self.ctx.save()
        return changed

    def after_edit(self, changed: list[str]) -> None:
        pass

    def kept(self) -> list[str]:
        return [it.name for it in self.kept_items()]

    def load(self, index: int) -> None:
        items = self.kept_items()
        if 0 <= index < len(items):
            self.set_draft(copy.deepcopy(items[index].params))
            self.ctx.save()

    def delete(self, index: int) -> None:
        items = self.kept_items()
        if 0 <= index < len(items):
            items.pop(index)
            self.ctx.save()

    def do_keep(self) -> str | None:
        name = self.keep()
        if name:
            self.ctx.save()
        return name


# ====================================================================== Perfis
class AirfoilStage(Stage):
    name = "perfis"
    title = "Perfil"
    help = ("Perfis candidatos e a polar 2D de cada um no Re do cruzeiro. O perfil pode vir de um código NACA, "
            "de um .dat, só de parâmetros (sem contorno) ou da polar do XFLR5/XFOIL. 'Usar na asa' leva o "
            "perfil selecionado para a etapa Asa.")
    keep_label = "Usar na asa →"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.selected = 0

    def entries(self):
        return self.ctx.design.airfoils

    def draft(self):
        e = self.entries()
        self.selected = min(max(self.selected, 0), len(e) - 1) if e else 0
        return e[self.selected] if e else None

    def choices(self):
        d = self.draft()
        return {"source": tuple(afm.sources(d))} if d is not None else {}

    def exclude(self):
        return ("polar_file",)

    def sanitize(self):
        pass

    def kept(self):
        return [f"{e.name}   ({afm.kind(e.airfoil)}, polar: {e.source})" for e in self.entries()]

    def load(self, index):                       # aqui a lista é a dos candidatos: carregar = selecionar
        if 0 <= index < len(self.entries()):
            self.selected = index

    def delete(self, index):
        if 0 <= index < len(self.entries()):
            self.entries().pop(index)
            self.ctx.save()

    def reynolds(self) -> float:
        d = self.ctx.design
        pf = wg.planform(wg.build_wing(d.wing_draft, afm.Airfoil()))
        return d.requirements.reynolds(pf["mac"])

    def compute(self):
        Re = self.reynolds()
        specs, res = R.airfoil_stage(self.entries(), Re)
        return Outcome(specs, res, message=f"Re = {Re:,.0f}".replace(",", " ") + " (cruzeiro, corda média da asa)")

    def keep(self):
        e = self.draft()
        if e is None:
            return None
        self.ctx.design.wing_draft.airfoil = e.name
        return e.name

    def actions(self):
        return [Action("naca", "+ NACA…", "text", "código de 4 dígitos", "4412"),
                Action("dat", "+ .dat…", "file", "contorno Selig ou Lednicer"),
                Action("param", "+ só parâmetros", "", "sem contorno: a1, α_L0, c_l,max, c_d0, c_m"),
                Action("polar", "+ polar XFLR5…", "file", "polar exportada (texto ou CSV); vai para o perfil selecionado")]

    def _add(self, e) -> str:
        if e.name in [x.name for x in self.entries()]:
            return f"'{e.name}' já está na lista."
        self.entries().append(e)
        self.selected = len(self.entries()) - 1
        self.ctx.save()
        return f"entrou: {e.name}"

    def act(self, key, arg):
        if key == "naca":
            if len("".join(c for c in arg if c.isdigit())) != 4:
                return "o código NACA tem 4 dígitos"
            return self._add(afm.entry(afm.from_naca(arg)))
        if key == "dat":
            return self._add(afm.entry(afm.from_dat(arg)))
        if key == "param":
            n = len(self.entries()) + 1
            return self._add(afm.AirfoilEntry(afm.Airfoil(name=f"perfil {n}", alpha0=-3.0, cm_ac=-0.08, cl_max=1.5)))
        if key == "polar":
            p = afm.read_polar_file(arg)
            e = self.draft()
            if e is None:
                e = afm.AirfoilEntry(afm.Airfoil(name=os.path.splitext(os.path.basename(arg))[0]))
                self.entries().append(e)
            e.polar_file = arg
            e.source = "arquivo"
            self.ctx.save()
            return f"polar lida: {len(p['alpha'])} pontos, Re {p['Re']:.3g}"
        return super().act(key, arg)


# ====================================================================== Asa
class WingStage(Stage):
    name = "asa"
    title = "Asa"
    help = ("A asa a partir do perfil escolhido: forma em planta, linha sustentadora, onde o estol começa, polar e "
            "L/D. A incidência sai do ângulo de cruzeiro. Guarde as asas que quiser comparar: a etapa Empenagem "
            "parte de uma delas.")
    keep_label = "Guardar asa"
    TRAPEZOID_ONLY = ("span", "area", "chord", "size_by", "taper", "rect_frac", "sweep", "twist", "airfoil",
                      "airfoil_tip")

    def draft(self):
        return self.ctx.design.wing_draft

    def set_draft(self, params):
        self.ctx.design.wing_draft = params

    def choices(self):
        names = self.ctx.design.airfoil_names()
        return {"airfoil": names, "airfoil_tip": ("",) + names}

    def kept_items(self):
        return self.ctx.design.wings

    def after_edit(self, changed):
        p = self.draft()
        table = p.planform == wg.PLANFORMS[1]
        if table and not p.partitions:
            p.partitions = wg.partitions_from_trapezoid(p)
        if table or any(k in ("planform", "size_by") for k in changed):
            wg.sync(p)

    def disabled(self):
        p = self.draft()
        if p.planform == wg.PLANFORMS[1]:
            return self.TRAPEZOID_ONLY
        return ("area",) if p.size_by == wg.SIZE_BY[1] else ("chord",)

    def compute(self):
        d = self.ctx.design
        cand = d.draft_wing()
        others = [w for w in d.wings if w.name != cand.name]
        specs, res, r = R.wing_stage(cand, d.requirements, d.rules, others)
        self.ctx.values.update(rg.wing_values(r))
        surfaces = self._layout_surfaces()
        if len(surfaces) > 1:                  # o ponto neutro do rascunho sozinho não vale para o conjunto
            return Outcome(specs, res, aircraft=only_surfaces(surfaces))
        return Outcome(specs, res, aircraft=only_surfaces([r["surface"]]), markers=dict(np_x=r["planform"]["x_ac"]))

    def _layout_surfaces(self):
        """as asas da tabela, cada uma no lugar dela (a vista 3D mostra o avião com todas)"""
        return self.ctx.design.layout_surfaces()

    # a tabela de partições (a mesma de `WingPage` na GUI PyQt)
    COLUMNS = (("span", "envergadura (m)", "quanto a partição soma na envergadura total (metade de cada lado)"),
               ("chord", "corda (m)", "corda no começo da partição (do lado do centro)"),
               ("taper", "afilamento", "corda no fim / corda no começo (1 = reta)"),
               ("airfoil", "perfil", "perfil no fim da partição (vazio = o da raiz); ao longo dela ele passa do da "
                                     "anterior para este"),
               ("offset", "recuo (m)", "quanto o bordo de ataque anda para trás ao longo da partição "
                                       "(enflechamento): move o centro aerodinâmico, e com ele o CG de projeto. 0 = "
                                       "bordo de ataque reto"),
               ("twist", "θ (°)", "torção no fim da partição, em relação à raiz: − = washout, a ponta estola depois "
                                  "(o aileron continua mandando no estol), custa um pouco de sustentação"))
    GRID_BUTTONS = (("add", "+ partição", "nova partição depois da selecionada (ou no fim), começando com a corda em "
                                          "que a anterior termina"),
                    ("delete", "− partição", "apaga a selecionada (fica pelo menos uma)"),
                    ("reset", "do trapézio", "refaz a tabela a partir do trapézio atual"))

    # a tabela das asas do avião: quantas asas e onde cada uma fica em relação à primeira (a referência)
    LAYOUT_COLUMNS = (("wing", "asa", "uma das asas guardadas (a primeira linha é a referência)"),
                      ("dx", "Δx (m)", "bordo de ataque da raiz em relação ao da referência: + para trás"),
                      ("dy", "Δy (m)", "+ para a direita"),
                      ("dz", "Δz (m)", "+ para cima (biplano: o vão entre as asas)"),
                      ("di", "decalagem (°)", "incidência dela menos a da referência"),
                      ("join", "pontas ligadas", "uma placa liga a ponta dela à da referência (asa em caixa)"))
    JOIN = ("não", "sim")
    LAYOUT_BUTTONS = (("add", "+ asa", "mais uma asa guardada, depois da selecionada (ou no fim)"),
                      ("delete", "− asa", "tira a selecionada da lista"))

    # a tabela dos dispositivos das asas do avião (o `WingDevice` do modelo, por linha da tabela de asas)
    DEVICE_COLUMNS = (("wing", "asa", "em qual linha da tabela 'Asas do avião' ele fica"),
                      ("kind", "tipo", "winglet: para cima; winglet_baixo: para baixo; placa: metade para cima e "
                                       "metade para baixo; cerca: placa fina sobre o extradorso"),
                      ("eta", "posição", "onde, na semienvergadura: 0 = raiz, 1 = ponta"),
                      ("dx", "recuo (m)", "do bordo de ataque dele em relação ao da asa ali: + para trás"),
                      ("height", "altura (m)", "na placa, a soma das duas metades"),
                      ("root_chord", "corda (m)", "na raiz dele; 0 = a corda da asa ali"),
                      ("taper", "afilamento", "corda da ponta / corda da raiz"),
                      ("sweep", "enflechamento (°)", "do bordo de ataque"),
                      ("cant", "inclinação (°)", "a partir da vertical: 0 = vertical, 90 = no plano da asa"),
                      ("toe", "calagem (°)", "+ bordo de ataque para fora"),
                      ("profile", "perfil", "o perfil dele"))
    DEVICE_BUTTONS = (("add", "+ dispositivo", "um winglet na ponta da asa do selecionado (ou da primeira)"),
                      ("delete", "− dispositivo", "tira o selecionado"))

    def grids(self):
        return self._layout_grid() + self._device_grid() + self._partition_grid()

    def _device_rows(self) -> list:
        """(linha da tabela de asas, dispositivo), na ordem da tabela"""
        return [(k, x) for k, r in enumerate(self.ctx.design.wing_layout) for x in r.devices]

    def _device_grid(self):
        from aerosim.model.aircraft import DEVICE_KINDS
        d = self.ctx.design
        if not d.wing_layout:
            return []
        wings = tuple(f"{k + 1}: {r.wing}" for k, r in enumerate(d.wing_layout))
        profiles = tuple(dict.fromkeys(TAIL_AIRFOILS + d.airfoil_names()))
        rows = self._device_rows()
        profiles += tuple(x.profile for _, x in rows if x.profile not in profiles)
        kinds = {"wing": ("choice", wings), "kind": ("choice", DEVICE_KINDS), "profile": ("choice", profiles)}
        columns = [GridColumn(k, label, kinds.get(k, ("float",))[0], kinds.get(k, (None, ()))[1], tip)
                   for k, label, tip in self.DEVICE_COLUMNS]
        return [Grid("dispositivos", "Dispositivos das asas", columns,
                     [[wings[k] if c == "wing" else getattr(x, c) for c, _, _ in self.DEVICE_COLUMNS] for k, x in rows],
                     "vão com a configuração guardada; a Empenagem e o avião montado levam cada um na asa dele.",
                     "winglets, placas de ponta e cercas, cada um preso a uma asa da tabela acima, com a geometria "
                     "dele. O 3D mostra cada um no lugar.", list(self.DEVICE_BUTTONS))]

    def _layout_grid(self):
        d = self.ctx.design
        names = tuple(w.name for w in d.wings)
        if not names:
            return []
        extra = tuple(r.wing for r in d.wing_layout if r.wing not in names)
        kinds = {"wing": ("choice", names + extra), "join": ("choice", self.JOIN)}
        columns = [GridColumn(k, label, kinds.get(k, ("float",))[0], kinds.get(k, (None, ()))[1], tip)
                   for k, label, tip in self.LAYOUT_COLUMNS]
        note = "a primeira linha é a referência (Δ = 0); 'Guardar configuração' leva estas asas para a Empenagem."
        return [Grid("asas", "Asas do avião", columns,
                     [[self.JOIN[int(r.join)] if k == "join" else getattr(r, k) for k, _, _ in self.LAYOUT_COLUMNS]
                      for r in d.wing_layout], note,
                     "quantas asas o avião tem e onde fica cada uma, com base na primeira: uma linha é monoplano, "
                     "duas lado a lado em Δz são um biplano, uma atrás da outra em Δx um tandem.",
                     list(self.LAYOUT_BUTTONS))]

    def _partition_grid(self):
        p = self.draft()
        if p.planform != wg.PLANFORMS[1]:
            return []
        names = ("",) + tuple(self.ctx.design.airfoil_names())
        columns = [GridColumn(k, label, "choice" if k == "airfoil" else "float",
                              names if k == "airfoil" else (), tip) for k, label, tip in self.COLUMNS]
        extra = tuple(q.airfoil for q in p.partitions if q.airfoil not in names)
        if extra:
            columns[3].choices = names + extra
        b, S = wg.totals(p)
        note = f"envergadura total: {b:.3f} m · área: {S:.4f} m² · alongamento: " \
               f"{b * b / S if S > 0 else float('nan'):.2f}"
        return [Grid("partições", "Partições (do centro para a ponta)", columns,
                     [[getattr(q, k) for k, _, _ in self.COLUMNS] for q in p.partitions], note,
                     "uma linha por partição, como na planilha: envergadura, corda, afilamento, perfil, recuo e "
                     "torção. A envergadura total é a soma das partições. Uma asa reta é uma linha só (afilamento 1).",
                     list(self.GRID_BUTTONS))]

    def edit_grid(self, name, op, row, key="", value=None):
        if name == "asas":
            self._edit_layout(op, row, key, value)
        elif name == "dispositivos":
            self._edit_devices(op, row, key, value)
        else:
            self._edit_partitions(op, row, key, value)
        self.ctx.save()

    def _edit_layout(self, op, row, key, value):
        d = self.ctx.design
        rows = d.wing_layout
        row = row if 0 <= row < len(rows) else len(rows) - 1
        if op == "set" and rows:
            if key == "wing":
                rows[row].wing = str(value or "")
            elif key == "join":
                rows[row].join = row > 0 and str(value) in (self.JOIN[1], "True", "1")
            elif row > 0:                                  # a referência fica em Δ = 0
                setattr(rows[row], key, float(value))
        elif op == "add":
            if not rows:
                rows.append(wg.WingPlacement(d.tail_draft.wing or d.wings[0].name))
            else:
                rows.insert(row + 1, wg.WingPlacement(rows[row].wing))
        elif op == "delete":
            if rows:
                rows.pop(row)
        else:
            raise KeyError(op)
        d.apply_wing_layout()

    def _edit_devices(self, op, row, key, value):
        from aerosim.model.aircraft import WingDevice
        layout = self.ctx.design.wing_layout
        rows = self._device_rows()
        row = row if 0 <= row < len(rows) else len(rows) - 1
        if op == "set" and rows:
            k, x = rows[row]
            if key == "wing":                                  # muda de asa: "2: asa bi" → a linha 2
                target = int(str(value).split(":")[0]) - 1
                if 0 <= target < len(layout) and target != k:
                    _drop(layout[k].devices, x)
                    layout[target].devices.append(x)
            elif key in ("kind", "profile"):
                setattr(x, key, str(value))
            else:
                setattr(x, key, float(value))
        elif op == "add" and layout:
            k = rows[row][0] if rows else 0
            layout[k].devices.append(WingDevice())
        elif op == "delete":
            if rows:
                k, x = rows[row]
                _drop(layout[k].devices, x)
        else:
            raise KeyError(op)
        self.ctx.design.apply_wing_layout()

    def _edit_partitions(self, op, row, key, value):
        p = self.draft()
        parts = p.partitions
        row = row if 0 <= row < len(parts) else len(parts) - 1
        if op == "set":
            if key == "airfoil":
                setattr(parts[row], key, str(value or ""))
            else:
                number = float(value)
                setattr(parts[row], key, max(number, 0.0) if key in ("span", "chord", "taper") else number)
        elif op == "add":
            a = parts[row]
            parts.insert(row + 1, wg.WingPartition(0.2, round(a.chord * a.taper, 4), 1.0, a.airfoil, 0.0, a.twist))
        elif op == "delete":
            if len(parts) > 1:
                parts.pop(row)
        elif op == "reset":
            p.partitions = wg.partitions_from_trapezoid(p)
        else:
            raise KeyError(op)
        wg.sync(p)

    def keep(self):
        d = self.ctx.design
        c = d.keep_wing()
        d.tail_draft.wing = c.name
        return c.name

    def actions(self):
        from aerosim.design.project import next_name
        d = self.ctx.design
        return [Action("config", "Guardar configuração", "text",
                       "guarda as asas da tabela 'Asas do avião' (quais e onde) com um nome; a Empenagem passa a usar "
                       "esta configuração", next_name("configuração 1", [c.name for c in d.configs]))]

    def act(self, key, arg):
        if key != "config":
            return super().act(key, arg)
        c = self.ctx.design.keep_config(arg)
        if c is None:
            return "A tabela 'Asas do avião' está vazia: ponha pelo menos uma asa (+ asa)."
        self.ctx.save()
        return f"configuração guardada: {c.name} ({len(c.wings)} asa{'s' if len(c.wings) > 1 else ''}); a " \
               f"Empenagem usa esta"


# ====================================================================== Empenagem
# os campos da segunda asa: quem diz quantas asas há e onde ficam é a configuração de Projetar, não a Empenagem
SECOND_WING_KEYS = ("wing2", "wing2_dx", "wing2_dy", "wing2_dz", "wing2_join", "wing2_di", "wing2_area", "wing2_span",
                    "wing2_sweep", "wing2_airfoil")


class TailStage(Stage):
    name = "empenagem"
    title = "Empenagem e comandos"
    help = ("As superfícies que acompanham a asa guardada: cauda (convencional, em V ou sem cauda), tubo, "
            "profundor, leme e aileron, por volume de cauda. Põe o CG na margem pedida e diz a faixa de CG, a "
            "incidência da EH e se os comandos dão conta. Guarde conjuntos para a etapa Motores.")
    keep_label = "Guardar conjunto"

    def draft(self):
        return self.ctx.design.tail_draft

    def set_draft(self, params):
        self.ctx.design.tail_draft = params

    def choices(self):
        d = self.ctx.design
        from aerosim.design.tail import LIVE_LAYOUT
        return {"config": (LIVE_LAYOUT,) + tuple(c.name for c in d.configs),
                "wing": tuple(w.name for w in d.wings),
                "tail_airfoil": tuple(dict.fromkeys(TAIL_AIRFOILS + d.airfoil_names())),
                "vtail_airfoil": tuple(dict.fromkeys(TAIL_AIRFOILS + d.airfoil_names()))}

    def editable(self):
        return ("tail_airfoil", "vtail_airfoil")

    # a tabela de comandos: cada linha é um `ControlSurface` do modelo numa superfície do conjunto
    CONTROL_COLUMNS = (("surface", "superfície", "em qual superfície do conjunto ele fica"),
                       ("kind", "nome", "só o nome (aileron, profundor, elevon...): o que ele faz são os ganhos"),
                       ("span_start", "início", "fração da semienvergadura (0 = raiz)"),
                       ("span_end", "fim", "fração da semienvergadura (1 = ponta)"),
                       ("chord_frac", "corda", "fração da corda"),
                       ("pitch", "arfagem", "ganho de arfagem: +1 desce o bordo de fuga para picar (atrás do CG); −1 "
                                            "à frente do CG, onde descer cabra"),
                       ("roll", "rolagem", "ganho de rolagem: os dois lados em sentidos opostos"),
                       ("yaw", "guinada", "ganho de guinada"))
    CONTROL_KINDS = ("aileron", "elevator", "rudder", "elevon", "ruddervator", "flaperon", "flap")
    CONTROL_BUTTONS = (("rule", "da regra", "enche a tabela com os comandos que a regra da etapa põe (aileron ou "
                                            "elevon na asa, profundor na EH, leme na EV), para editar"),
                       ("add", "+ comando", "um comando novo na superfície do selecionado"),
                       ("delete", "− comando", "tira o selecionado"),
                       ("clear", "limpar", "esvazia a tabela: volta a valer a regra da etapa"))
    RULE_KEYS = ("elevator", "rudder", "aileron_start", "aileron_end", "aileron_chord")

    def exclude(self):
        # a segunda asa vem da configuração; onde ficam a arfagem e as derivas de um tandem, da tabela de comandos
        return SECOND_WING_KEYS + ("controls", "tandem_pitch", "tip_fin_where")

    def _built(self, rule: bool = False):
        """o conjunto montado (só as superfícies), com a tabela ou, `rule`, com a regra da etapa"""
        from aerosim.design import tail as tl
        d = self.ctx.design
        cand = d.draft_set()
        if cand is None:
            return None
        if rule:
            cand.params.controls = []
        return tl.build_set(cand, d.requirements, d.rules, airfoils=d.airfoil_map())[0]

    def grids(self):
        ac = self._built()
        if ac is None:
            return []
        rows = self.ctx.design.tail_draft.controls
        names = tuple(s.name for s in ac.surfaces)
        names += tuple(dict.fromkeys(r.surface for r in rows if r.surface not in names))
        kinds = self.CONTROL_KINDS + tuple(dict.fromkeys(r.control.kind for r in rows
                                                         if r.control.kind not in self.CONTROL_KINDS))
        choice = {"surface": names, "kind": kinds}
        columns = [GridColumn(k, label, "choice" if k in choice else "float", choice.get(k, ()), tip)
                   for k, label, tip in self.CONTROL_COLUMNS]

        def cells(r):
            g = r.control.gains
            return [r.surface, r.control.kind, r.control.span_start, r.control.span_end, r.control.chord_frac, *g]
        note = ("vazia: vale a regra da etapa ('da regra' mostra qual é). Com linhas, a tabela manda em todas as "
                "superfícies.")
        return [Grid("comandos", "Comandos", columns, [cells(r) for r in rows], note,
                     "um comando por linha, em qualquer superfície do conjunto: o trecho da envergadura, a fração da "
                     "corda e quanto ele responde a cada eixo (arfagem, rolagem, guinada). Um profundor à frente do "
                     "CG leva arfagem −1.", list(self.CONTROL_BUTTONS))]

    def edit_grid(self, name, op, row, key="", value=None):
        from aerosim.design import tail as tl
        from aerosim.model.aircraft import ControlSurface
        if name != "comandos":
            raise KeyError(name)
        tp = self.ctx.design.tail_draft
        rows = tp.controls
        row = row if 0 <= row < len(rows) else len(rows) - 1
        if op == "set" and rows:
            r = rows[row]
            if key == "surface":
                r.surface = str(value)
            elif key == "kind":
                r.control.kind = str(value)
            elif key in ("pitch", "roll", "yaw"):
                g = list(r.control.gains)
                g[("pitch", "roll", "yaw").index(key)] = float(value)
                r.control.mix = g
            else:
                setattr(r.control, key, float(value))
        elif op == "rule":
            ac = self._built(rule=True)
            tp.controls = tl.rule_controls(ac) if ac is not None else []
        elif op == "add":
            ac = self._built()
            where = rows[row].surface if rows else (ac.surfaces[0].name if ac is not None else "")
            rows.append(tl.SurfaceControl(where, ControlSurface("aileron", 0.6, 1.0, 0.25, mix=[0.0, 1.0, 0.0])))
        elif op == "delete":
            if rows:
                rows.pop(row)
        elif op == "clear":
            tp.controls = []
        else:
            raise KeyError(op)
        self.ctx.save()

    def disabled(self):
        """com uma configuração (ou a tabela de Projetar preenchida), a asa vem de lá; com a tabela de comandos, os
        campos da regra dos comandos não valem"""
        d = self.ctx.design
        return (("wing",) if d.layout_rows() else ()) + (self.RULE_KEYS if d.tail_draft.controls else ())

    def after_edit(self, changed):
        if "config" not in changed:
            return
        d = self.ctx.design
        if d.layout_rows():
            d.apply_wing_layout()
        else:                                  # a tabela vazia: só a asa, sem a segunda escondida da anterior
            from aerosim.design.tail import NO_WING2
            d.tail_draft.wing2 = NO_WING2

    def kept_items(self):
        return self.ctx.design.sets

    def compute(self):
        d = self.ctx.design
        cand = d.draft_set()
        if cand is None:
            return Outcome(message="Guarde uma asa primeiro (Aerodinâmica → Projetar → Guardar asa).")
        specs, res, r = R.set_stage(cand, d.requirements, d.rules, d.airfoil_map())
        ac = r["set"]
        return Outcome(specs, res, tables=[dims_table(ac, cg=(r["x_cg"], 0.0, 0.0))],
                       aircraft=only_surfaces(ac.surfaces, ac.boom), markers=dict(cg=[r["x_cg"], 0.0, 0.0],
                                                                                  np_x=r["x_np"]))

    def keep(self):
        d = self.ctx.design
        c = d.keep_set()
        if c is None:
            return None
        d.power_draft.set = c.name
        return c.name


# ====================================================================== Motores e montagem
class PowerStage(Stage):
    name = "motores"
    title = "Motores e montagem"
    help = ("Onde ficam os motores, e com isso a bateria (posta onde o CG cai na margem), a carga paga (no CG), a "
            "fuselagem e o trem. Mostra o desempenho rápido do avião montado e a massa máxima que a pista permite. "
            "'Mandar para a Montagem' abre o avião e o salva em 'meus aviões'.")
    keep_label = "Guardar avião"

    def draft(self):
        return self.ctx.design.power_draft

    def set_draft(self, params):
        self.ctx.design.power_draft = params

    def choices(self):
        cat = self.ctx.catalog
        return {"set": tuple(s.name for s in self.ctx.design.sets),
                "motor": tuple(m.name for m in cat.motors), "propeller": tuple(p.name for p in cat.propellers),
                "battery": tuple(b.name for b in cat.batteries),
                "thrust_set": tuple(t.name for t in cat.thrust_sets) or ("",)}

    def kept_items(self):
        return self.ctx.design.aircraft

    def compute(self):
        d = self.ctx.design
        cand = d.draft_aircraft()
        if cand is None:
            return Outcome(message="Guarde um conjunto primeiro (Estabilidade → Empenagem e comandos → Guardar "
                                   "conjunto).")
        specs, res, ac, asm, pf = R.aircraft_stage(cand, d.requirements, d.rules, self.ctx.catalog,
                                                   self.ctx.backend, d.airfoil_map())
        self.ctx.values.update(rg.aircraft_values(ac, asm, pf, cand.params))
        return Outcome(specs, res, tables=[self.mass_table(asm, pf), dims_table(ac)], aircraft=ac,
                       markers=dict(cg=[asm["x_cg_target"], 0.0, 0.0]))

    @staticmethod
    def mass_table(asm: dict, pf: dict) -> Table:
        M = asm["mass"]
        rows = [[g, n, f"{m:.3f}", f"{x:.3f}", f"{100 * m / M:.1f}"] for g, n, m, x in asm["mass_table"]]
        rows += [["PV", "peso vazio", f"{asm['empty']:.3f}", "", f"{100 * asm['empty'] / M:.1f}"],
                 ["CP", "carga paga", f"{asm['payload']:.3f}", "", f"{100 * asm['payload'] / M:.1f}"],
                 ["", "total", f"{M:.3f}", f"{asm['x_cg_target']:.3f} (CG)", "100"]]
        mt = pf.get("mtow_runway", float("nan"))
        if mt == mt:
            rows.append(["", "MTOW pela pista → CP possível = MTOW − PV", f"{mt:.3f}", "", f"CP {mt - asm['empty']:.2f} kg"])
        return Table("Distribuição de massa", ("grupo", "item", "massa (kg)", "x (m)", "% do total"), rows)

    def keep(self):
        c = self.ctx.design.keep_aircraft()
        return None if c is None else c.name

    def actions(self):
        return [Action("send", "Mandar para a Montagem →", "",
                       "abre o avião do rascunho como novo avião e salva em 'meus aviões'")]

    def act(self, key, arg):
        if key != "send":
            return super().act(key, arg)
        from aerosim.design import power as pw
        from aerosim.design.flight import tune_takeoff
        d = self.ctx.design
        cand = d.draft_aircraft()
        if cand is None:
            return "Guarde um conjunto primeiro."
        ac, _ = pw.assemble(cand, d.requirements, d.rules, self.ctx.catalog, d.airfoil_map())
        try:
            ok, why = tune_takeoff(ac, self.ctx.backend)
        except Exception as error:
            ok, why = False, f"a decolagem não rodou ({error})"
        store = self.ctx.projects
        name, k = ac.name, 2
        while store.exists(name):
            name = f"{ac.name} ({k})"
            k += 1
        ac.name = name
        path = store.save(ac, name).path
        note = why if ok else f"⚠ foi sem a decolagem ajustada: {why}. Ajuste em Desempenho → Missão."
        return f"open:{path}|{ac.name}: {note}"


# ====================================================================== Condições e restrições
class RequirementsStage(Stage):
    """as condições e as regras do projeto (as abas Condições e Regras da janela "Condições e restrições…")"""
    name = "requisitos"
    title = "Condições e restrições"
    keep_label = ""

    def draft(self):
        return self.ctx.design.requirements

    def form(self):
        d = self.ctx.design
        return (forms.specs(d.requirements, group="Condições", prefix="req.")
                + forms.specs(d.rules, group="Regras de projeto", prefix="rules."))

    def set(self, values):
        d = self.ctx.design
        changed = forms.apply(d.requirements, {k[4:]: v for k, v in values.items() if k.startswith("req.")})
        changed += forms.apply(d.rules, {k[6:]: v for k, v in values.items() if k.startswith("rules.")})
        if changed:
            self.ctx.save()
        return changed

    def compute(self):
        return Outcome(message=self.ctx.design.requirements.summary())

    def keep(self):
        return None

    CONSTRAINT_COLUMNS = (("active", "ativa", "check", "ligue ou desligue sem perder o valor"),
                          ("key", "grandeza", "choice", "o que se limita"),
                          ("op", "op.", "choice", "≤, ≥ ou = (com a tolerância de 2 %)"),
                          ("value", "valor", "float", "o limite"),
                          ("unit", "unid.", "label", ""),
                          ("calc", "calculado", "label", "o valor da última etapa que rodou"),
                          ("status", "situação", "label", "desligada, ✔ cumpre ou ✖ não cumpre"))
    VARIABLE_COLUMNS = (("label", "entrada", "label", ""),
                        ("mode", "modo", "choice", "fixo: o valor do rascunho; variável: o otimizador procura entre mín. "
                                                   "e máx. (listas: entre as opções); calculado: sai das contas"),
                        ("value", "valor (fixo)", "text", "o valor do rascunho da etapa"),
                        ("lo", "mín.", "float", ""),
                        ("hi", "máx.", "float", ""),
                        ("options", "opções (listas)", "text", "os nomes separados por vírgula; vazio = todos"))

    def grids(self):
        d = self.ctx.design
        keys = list(rg.QUANTITIES)
        labels = tuple(rg.QUANTITIES[k].label for k in keys)
        values = self.ctx.values

        def constraint(c):
            x = values.get(c.key)
            status = ("desligada" if not c.active else "—" if x is None
                      else "✔ cumpre" if c.holds(x) else "✖ não cumpre")
            return [c.active, c.quantity.label, c.op, c.value, c.quantity.unit,
                    rg.fmt(x) if x is not None else "—", status]
        choice = {"key": labels, "op": rg.OPS}
        restrictions = Grid(
            "restricoes", "Restrições",
            [GridColumn(k, label, kind, choice.get(k, ()), tip) for k, label, kind, tip in self.CONSTRAINT_COLUMNS],
            [constraint(c) for c in d.requirements.constraints],
            "as etapas conferem as ativas no diagnóstico; o estudo marca como inviável o ponto que não cumpre",
            "restrições de projeto; 'calculado' é o valor da última etapa que rodou",
            [("add", "+ restrição", ""), ("delete", "− restrição", "")])

        known = {v.key for v in d.variables}
        d.variables += [rg.Variable(k, "fixo", i.lo, i.hi) for k, i in rg.INPUTS.items() if k not in known]

        def variable(v):
            inp = v.input
            listed = inp.unit == "lista"
            try:
                current = rg.get_input(d, v.key)
            except AttributeError:
                current = ""
            label = inp.label + ("" if listed or not inp.unit else f" ({inp.unit})")
            shown = current if isinstance(current, str) else f"{current:g}"
            return [label, v.mode, shown, None if listed else v.lo, None if listed else v.hi,
                    ", ".join(v.options) if listed else None]
        variables = Grid(
            "variaveis", "Variáveis",
            [GridColumn(k, label, kind, rg.MODES if k == "mode" else (), tip)
             for k, label, kind, tip in self.VARIABLE_COLUMNS],
            [variable(v) for v in d.variables],
            "PV e MTOW são saídas. 'Limites das restrições' leva as restrições ativas para o mín. e o máx. "
            "(envergadura, área, nº de motores)",
            "entradas de projeto: o que fica fixo, o que o otimizador varia e o que sai das contas",
            [("bounds", "Limites das restrições", "")])
        return [restrictions, variables]

    def edit_grid(self, name, op, row, key="", value=None):
        d = self.ctx.design
        if name == "restricoes":
            rows = d.requirements.constraints
            row = row if 0 <= row < len(rows) else len(rows) - 1
            if op == "set" and rows:
                c = rows[row]
                if key == "active":
                    c.active = bool(value)
                elif key == "key":
                    c.key = next((k for k, q in rg.QUANTITIES.items() if q.label == value), c.key)
                elif key == "op":
                    c.op = str(value)
                elif key == "value":
                    c.value = float(value)
            elif op == "add":
                rows.append(rg.Constraint("S", "≤", 1.0))
            elif op == "delete":
                if rows:
                    rows.pop(row)
            else:
                raise KeyError(op)
        elif name == "variaveis":
            rows = d.variables
            if op == "bounds":
                rg.bounds_from_constraints(d)
            elif op == "set" and 0 <= row < len(rows):
                v = rows[row]
                if key == "mode":
                    v.mode = str(value)
                elif key in ("lo", "hi"):
                    setattr(v, key, float(value))
                elif key == "value":
                    current = rg.get_input(d, v.key)
                    rg.set_input(d, v.key, str(value) if isinstance(current, str) else float(str(value).replace(",", ".")))
                elif key == "options":
                    v.options = [x.strip() for x in str(value).split(",") if x.strip()]
                    if v.mode == "fixo" and v.options:
                        v.mode = "variável"          # escolheu opções: a busca varia entre elas (como na PyQt)
            elif op != "set":
                raise KeyError(op)
        else:
            raise KeyError(name)
        self.ctx.save()


STAGES = {cls.name: cls for cls in (AirfoilStage, WingStage, TailStage, PowerStage, RequirementsStage)}

# onde cada etapa entra na janela (a mesma ordem de `aerosim/gui/design/__init__.py`: as etapas antes da análise
# do avião montado); o título da subaba é o da GUI PyQt
PLACES = {
    "aerodinamica": (("Perfis", "perfis"), ("Projetar", "asa")),
    "estabilidade": (("Empenagem e comandos", "empenagem"),),
    "desempenho": (("Motores e montagem", "motores"),),
}
