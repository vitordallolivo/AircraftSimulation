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

from aerosim.model.serialize import from_dict, to_dict

from . import airfoils as afm
from .power import AircraftCandidate, PowerParams
from .spec import DesignRules, Requirements
from .study import StudyParams, StudyRun
from .tail import SetCandidate, TailParams
from .wing import WingCandidate, WingParams


def _default_airfoils() -> list[afm.AirfoilEntry]:
    return [afm.entry(afm.from_naca("NACA 2412")), afm.entry(afm.from_naca("NACA 4412"))]


@dataclass
class DesignProject:
    requirements: Requirements = field(default_factory=Requirements)
    rules: DesignRules = field(default_factory=DesignRules)
    airfoils: list[afm.AirfoilEntry] = field(default_factory=_default_airfoils)
    wings: list[WingCandidate] = field(default_factory=list)
    sets: list[SetCandidate] = field(default_factory=list)
    aircraft: list[AircraftCandidate] = field(default_factory=list)
    wing_draft: WingParams = field(default_factory=WingParams)
    tail_draft: TailParams = field(default_factory=TailParams)
    power_draft: PowerParams = field(default_factory=PowerParams)
    study: StudyParams = field(default_factory=StudyParams)
    studies: list[StudyRun] = field(default_factory=list)       # os estudos rodados (dados de simulação)

    def keep_study(self, run: StudyRun) -> None:
        """guarda um estudo rodado (o mesmo estudo — modo, avião, variável, lugares — é substituído)"""
        self.studies = [r for r in self.studies if r.key() != run.key()] + [run]

    # ------------------------------------------------------------------ busca
    def airfoil(self, name: str) -> afm.AirfoilEntry | None:
        return next((a for a in self.airfoils if a.name == name), None)

    def wing(self, name: str) -> WingCandidate | None:
        return next((w for w in self.wings if w.name == name), None)

    def set(self, name: str) -> SetCandidate | None:
        return next((s for s in self.sets if s.name == name), None)

    def airfoil_map(self) -> dict:
        """nome → candidato da etapa Perfil (a cauda ajusta o perfil na polar dele, no Re dela)"""
        return {a.name: a for a in self.airfoils}

    # ------------------------------------------------------------------ guardar (mesmo nome: substitui)
    @staticmethod
    def _put(items: list, cand) -> None:
        for i, it in enumerate(items):
            if it.name == cand.name:
                items[i] = cand
                return
        items.append(cand)

    def keep_wing(self) -> WingCandidate:
        af = self.airfoil(self.wing_draft.airfoil) or (self.airfoils[0] if self.airfoils else afm.AirfoilEntry())
        c = WingCandidate(copy.deepcopy(self.wing_draft), copy.deepcopy(af))
        self._put(self.wings, c)
        self.wing_draft.name = next_name(self.wing_draft.name, [w.name for w in self.wings])
        return c

    def draft_wing(self) -> WingCandidate:
        af = self.airfoil(self.wing_draft.airfoil) or (self.airfoils[0] if self.airfoils else afm.AirfoilEntry())
        return WingCandidate(copy.deepcopy(self.wing_draft), copy.deepcopy(af))

    def draft_set(self) -> SetCandidate | None:
        w = self.wing(self.tail_draft.wing) or (self.wings[-1] if self.wings else None)
        return None if w is None else SetCandidate(copy.deepcopy(self.tail_draft), copy.deepcopy(w))

    def keep_set(self) -> SetCandidate | None:
        c = self.draft_set()
        if c is not None:
            c.params.wing = c.wing.name
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
            return from_dict(cls, json.load(f))


def next_name(name: str, taken: list[str]) -> str:
    """'asa 1' → 'asa 2' (o próximo número livre)"""
    base, _, num = name.rpartition(" ")
    if not base or not num.isdigit():
        base, num = name, "1"
    k = int(num)
    while f"{base} {k}" in taken:
        k += 1
    return f"{base} {k}"
