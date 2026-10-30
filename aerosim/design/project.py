"""O projeto da sprint: requisitos, regras e o que cada etapa guardou (perfis, asas, conjuntos, aviões).

Cada etapa trabalha num rascunho (`*_draft`) e guarda candidatos com nome; a etapa seguinte escolhe
um candidato da anterior pelo nome. O candidato leva uma cópia do que veio antes (a asa leva o perfil,
o conjunto leva a asa, o avião leva o conjunto), então apagar ou mudar um perfil depois não muda
uma asa já guardada. O programa não escolhe: guarda, compara e mostra.

    p = DesignProject()
    p.save("sprint.json");  p = DesignProject.load("sprint.json")
"""
from __future__ import annotations

import copy
import json
import os
from dataclasses import dataclass, field

from aerosim.model.aircraft import Aircraft, new_group_id
from aerosim.model.serialize import from_dict, to_dict

from . import airfoils as afm
from .power import AircraftCandidate, PowerParams
from .mdo import MdoParams, MdoRun
from .registry import Variable, default_variables
from .spec import DesignRules, Requirements
from .study import StudyParams, StudyRun
from .tail import LIVE_LAYOUT, NO_WING2, SAME_WING, SetCandidate, TailParams, wing2_candidate
from .wing import WingCandidate, WingConfig, WingParams, WingPlacement


def rg_sae():
    from .registry import sae_constraints
    return sae_constraints()


def _default_airfoils() -> list[afm.AirfoilEntry]:
    return [afm.entry(afm.from_naca("NACA 2412")), afm.entry(afm.from_naca("NACA 4412"))]


@dataclass
class DesignProject:
    requirements: Requirements = field(default_factory=lambda: Requirements(constraints=rg_sae()))
    rules: DesignRules = field(default_factory=DesignRules)
    airfoils: list[afm.AirfoilEntry] = field(default_factory=_default_airfoils)
    wings: list[WingCandidate] = field(default_factory=list)
    sets: list[SetCandidate] = field(default_factory=list)
    aircraft: list[AircraftCandidate] = field(default_factory=list)
    wing_draft: WingParams = field(default_factory=lambda: WingParams(taper=1.0, rect_frac=1.0))   # retangular
    tail_draft: TailParams = field(default_factory=TailParams)
    wing_layout: list[WingPlacement] = field(default_factory=list)   # as asas do avião (Projetar); vazia: a Empenagem escolhe
    configs: list[WingConfig] = field(default_factory=list)         # as configurações guardadas em Projetar
    power_draft: PowerParams = field(default_factory=PowerParams)
    study: StudyParams = field(default_factory=StudyParams)
    studies: list[StudyRun] = field(default_factory=list)       # os estudos rodados (dados de simulação)
    variables: list[Variable] = field(default_factory=default_variables)   # fixo / variável (faixa) / calculado
    mdo: MdoParams = field(default_factory=MdoParams)             # dimensionamento inicial (mini-MDO)
    mdo_runs: list[MdoRun] = field(default_factory=list)          # os resultados guardados (dados de simulação)
    fleet: list[Aircraft] = field(default_factory=list)         # os aviões abertos na Montagem (vazio: começa vazia)
    current: int = 0                                            # qual deles estava na tela
    runs: list[dict] = field(default_factory=list)              # o que já rodou nas abas (um por aba e avião)
    ui: dict = field(default_factory=dict)                      # onde a interface estava (aba, subaba)

    @staticmethod
    def migrate(data: dict) -> dict:
        """projetos antigos: variáveis que não existem mais (lastro, líquido e LAPES em kg viraram opções da
        etapa Motores; os kg se decidem na Montagem)"""
        from .registry import INPUTS
        if isinstance(data.get("variables"), list):
            data["variables"] = [v for v in data["variables"] if not isinstance(v, dict) or v.get("key") in INPUTS]
        return data

    def config(self, name: str) -> WingConfig | None:
        return next((c for c in self.configs if c.name == name), None)

    def layout_rows(self) -> list[WingPlacement]:
        """as asas que a Empenagem usa: as da configuração escolhida nela, ou as da tabela de Projetar"""
        c = self.config(self.tail_draft.config) if self.tail_draft.config != LIVE_LAYOUT else None
        return c.wings if c is not None else self.wing_layout

    def keep_config(self, name: str = "") -> WingConfig | None:
        """guarda a tabela de Projetar como uma configuração (o mesmo nome é substituído) e a Empenagem passa a usá-la"""
        if not self.wing_layout:
            return None
        name = name.strip() or next_name("configuração 1", [c.name for c in self.configs])
        c = WingConfig(name, copy.deepcopy(self.wing_layout))
        self._put(self.configs, c)
        self.tail_draft.config = c.name
        self.apply_wing_layout()
        return c

    def adopt_second_wing(self) -> None:
        """projetos de antes da configuração: a segunda asa da Empenagem (`wing2_*`) vira uma configuração de duas
        asas. Fica de fora a segunda asa escalada (área, envergadura, enflechamento ou perfil próprios, que o aeroopt
        usa): ela não é uma asa guardada, e a Empenagem continua montando-a como antes"""
        t = self.tail_draft
        scaled = (t.wing2_area, t.wing2_span, t.wing2_sweep, t.wing2_airfoil) != (1.0, 1.0, 0.0, "")
        if self.configs or self.wing_layout or t.wing2 in ("", NO_WING2) or scaled:
            return
        second = t.wing if t.wing2 == SAME_WING else t.wing2
        rows = [WingPlacement(t.wing), WingPlacement(second, t.wing2_dx, t.wing2_dy, t.wing2_dz, t.wing2_di,
                                                     t.wing2_join)]
        self.configs.append(WingConfig("configuração 1", rows))
        t.config = "configuração 1"

    def apply_wing_layout(self) -> None:
        """as asas da configuração (`layout_rows`) vão para a Empenagem: a primeira é a asa do conjunto e a segunda, a
        segunda asa (recuo, lado, desnível e decalagem em relação à primeira); da terceira em diante entram pelo
        conjunto (`draft_set`). Sem asas: a Empenagem fica como está."""
        rows = self.layout_rows()
        if not rows:
            return
        t = self.tail_draft
        t.wing = rows[0].wing
        if len(rows) < 2:
            t.wing2, t.wing2_dy, t.wing2_join = NO_WING2, 0.0, False
            return
        second = rows[1]
        t.wing2 = SAME_WING if second.wing == rows[0].wing else second.wing
        t.wing2_dx, t.wing2_dy, t.wing2_dz, t.wing2_di = second.dx, second.dy, second.dz, second.di
        t.wing2_join = second.join
        # a segunda asa é a guardada, como está: nada de escalar a área, a envergadura, o enflechamento ou o perfil
        t.wing2_area, t.wing2_span, t.wing2_sweep, t.wing2_airfoil = 1.0, 1.0, 0.0, ""

    def layout_surfaces(self) -> list:
        """as asas da tabela de Projetar como superfícies, cada uma no lugar dela (bordo de ataque da raiz da
        referência em x = 0), com a decalagem como incidência (o α de uma varredura é o da corda da referência) e as
        placas das pontas ligadas"""
        from .tail import join_tips
        surfaces = []
        for k, row in enumerate(self.wing_layout):
            s = self.wing_surface(row.wing)
            if s is None:
                continue
            s.name = f"{row.wing} ({k + 1})" if k else row.wing
            s.x, s.y, s.z = -row.dx, row.dy, -row.dz           # x e z do corpo: + para a frente, + para baixo
            s.incidence = row.di
            if k and row.join and surfaces:
                join_tips(surfaces[0], s)
            surfaces.append(s)
        return surfaces

    def summary(self) -> list[tuple[str, str]]:
        """o que está guardado, etapa por etapa (para mostrar ao abrir)"""
        names = lambda xs: ", ".join(x.name for x in xs) or "—"
        return [("perfis", names(self.airfoils)), ("asas", names(self.wings)),
                ("conjuntos asa + empenagem", names(self.sets)), ("aviões (motores e montagem)", names(self.aircraft)),
                ("estudos", ", ".join(f"{r.mode} ({len(r.rows)} pontos)" for r in self.studies) or "—"),
                ("Montagem", names(self.fleet) if self.fleet else "vazia")]

    def keep_study(self, run: StudyRun) -> None:
        """guarda um estudo rodado (o mesmo estudo — modo, avião, variável, lugares — é substituído)"""
        self.studies = [r for r in self.studies if r.key() != run.key()] + [run]

    # ------------------------------------------------------------------ busca
    def airfoil(self, name: str) -> afm.AirfoilEntry | None:
        """o candidato da etapa Perfil; senão o da biblioteca (data/airfoils)"""
        a = next((a for a in self.airfoils if a.name == name), None)
        return a if a is not None else afm.library().get(name)

    def airfoil_names(self) -> tuple[str, ...]:
        """os da etapa Perfil primeiro, depois os da biblioteca (data/airfoils)"""
        return tuple(dict.fromkeys([a.name for a in self.airfoils] + list(afm.library())))

    def wing(self, name: str) -> WingCandidate | None:
        return next((w for w in self.wings if w.name == name), None)

    def wing_surface(self, name: str):
        """a asa guardada `name` como superfície do avião (bordo de ataque da raiz em x = 0), com o perfil ajustado no
        Reynolds dela, como a etapa Asa mostra; None se não existe"""
        from .wing import analyze
        cand = self.wing(name)
        if cand is None:
            return None
        surface = analyze(cand, self.requirements, self.rules)["surface"]
        surface.name = name
        return surface

    def set(self, name: str) -> SetCandidate | None:
        return next((s for s in self.sets if s.name == name), None)

    def airfoil_map(self) -> dict:
        """nome → candidato: os da biblioteca (data/airfoils) e os da etapa Perfil, que valem por cima (a cauda
        ajusta o perfil na polar dele, no Re dela)"""
        return {**afm.library(), **{a.name: a for a in self.airfoils}}

    # ------------------------------------------------------------------ guardar (mesmo nome: substitui)
    @staticmethod
    def _put(items: list, cand) -> None:
        for i, it in enumerate(items):
            if it.name == cand.name:
                items[i] = cand
                return
        items.append(cand)

    def _tip(self):
        t = self.wing_draft.airfoil_tip
        e = self.airfoil(t) if t and t != self.wing_draft.airfoil else None
        return copy.deepcopy(e) if e is not None else None

    def _section_airfoils(self) -> list:
        """tabela de seções: cópias dos perfis das seções (fora o da raiz)"""
        p = self.wing_draft
        if not p.table():
            return []
        names = dict.fromkeys(q.airfoil for q in p.partitions if q.airfoil and q.airfoil != p.airfoil)
        return [copy.deepcopy(e) for e in (self.airfoil(n) for n in names) if e is not None]

    def draft_wing(self) -> WingCandidate:
        from .wing import sync
        sync(self.wing_draft)                     # área/corda/envergadura que saem dos outros campos
        af = self.airfoil(self.wing_draft.airfoil) or (self.airfoils[0] if self.airfoils else afm.AirfoilEntry())
        tip = None if self.wing_draft.table() else self._tip()
        return WingCandidate(copy.deepcopy(self.wing_draft), copy.deepcopy(af), airfoil_tip=tip,
                             section_airfoils=self._section_airfoils())

    def keep_wing(self) -> WingCandidate:
        c = self.draft_wing()
        self._put(self.wings, c)
        self.wing_draft.name = next_name(self.wing_draft.name, [w.name for w in self.wings])
        return c

    def draft_set(self) -> SetCandidate | None:
        w = self.wing(self.tail_draft.wing) or (self.wings[-1] if self.wings else None)
        if w is None:
            return None
        n2 = self.tail_draft.wing2
        w2 = w if n2 == SAME_WING else (self.wing(n2) if n2 and n2 != NO_WING2 else None)
        more = [(self.wing(r.wing), r) for r in self.layout_rows()[2:]]
        more = [(m, r) for m, r in more if m is not None]
        return SetCandidate(copy.deepcopy(self.tail_draft), copy.deepcopy(w),
                            wing2=wing2_candidate(w2, self.tail_draft, self.airfoil),
                            more_wings=[copy.deepcopy(m) for m, _ in more],
                            more_places=[copy.deepcopy(r) for _, r in more])

    def keep_set(self) -> SetCandidate | None:
        c = self.draft_set()
        if c is not None:
            c.params.wing = c.wing.name
            if c.wing2 is not None:                  # o id do par: sorteado uma vez, vai junto até a Montagem
                c.group = new_group_id({s.group for s in self.sets if s.group})
            self._put(self.sets, c)
            self.tail_draft.name = next_name(self.tail_draft.name, [s.name for s in self.sets])
        return c

    def draft_aircraft(self) -> AircraftCandidate | None:
        s = self.set(self.power_draft.set) or (self.sets[-1] if self.sets else None)
        return None if s is None else AircraftCandidate(copy.deepcopy(self.power_draft), copy.deepcopy(s))

    def keep_aircraft(self) -> AircraftCandidate | None:
        c = self.draft_aircraft()
        if c is not None:
            c.params.set = c.set.name
            self._put(self.aircraft, c)
            self.power_draft.name = next_name(self.power_draft.name, [a.name for a in self.aircraft])
        return c

    # ------------------------------------------------------------------ arquivo
    def save(self, path: str) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(to_dict(self), f, ensure_ascii=False, indent=1)

    @classmethod
    def load(cls, path: str) -> "DesignProject":
        with open(path, encoding="utf-8") as f:
            p = from_dict(cls, json.load(f))
        p.adopt_second_wing()
        return p


def is_project_file(path: str) -> bool:
    """um .json de projeto (etapas, estudos, Montagem) e não de um avião só"""
    if not path.lower().endswith(".json"):
        return False
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(d, dict) and any(k in d for k in ("requirements", "wings", "sets", "studies", "fleet"))


def next_name(name: str, taken: list[str]) -> str:
    """'asa 1' → 'asa 2' (o próximo número livre)"""
    base, _, num = name.rpartition(" ")
    if not base or not num.isdigit():
        base, num = name, "1"
    k = int(num)
    while f"{base} {k}" in taken:
        k += 1
    return f"{base} {k}"
