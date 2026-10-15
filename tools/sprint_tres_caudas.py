"""Exemplo: uma asa só com três opções de superfícies, no formato de pasta (um arquivo por asa).

    python tools/sprint_tres_caudas.py                 # → ./sprint_tres_caudas/
    python tools/sprint_tres_caudas.py ~/sprint_teste  # escolhendo a pasta

A asa, os perfis, os requisitos e as regras são os do projeto S1223 da equipe (data/sprint/projeto_s1223.json,
que não é alterado). As três opções da mesma asa:

    1. convencional: EH + EV, aileron na asa, tubo de cauda inclinado 6° para cima
                                                    (os parâmetros da "EH MH 113 invertida + EV HT 14" do projeto)
    2. cauda em V: EH + EV numa superfície só, aileron na asa  (os da "cauda em V MH 113 invertida")
    3. sem cauda: elevon na asa                     (os mesmos comandos de asa da opção 1)

e um avião para cada (o "monomotor" do projeto, trocando só a superfície), para usar direto em Desempenho.
Abra a pasta na interface: Projeto da sprint → Abrir pasta da sprint…
"""
import copy
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)

from aerosim.design import store  # noqa: E402
from aerosim.design.project import DesignProject  # noqa: E402

SAMPLE = os.path.join(ROOT, "data", "sprint", "projeto_s1223.json")
BOOM_PITCH = 6.0      # ° (+ ponta de trás para cima), só na opção 1
OPTIONS = (  # (nome da opção, superfície do projeto da equipe de onde vêm os parâmetros, cauda, inclinação do tubo)
    ("convencional: EH + EV + aileron, tubo inclinado", "EH MH 113 invertida + EV HT 14", "convencional", BOOM_PITCH),
    ("cauda em V: EH + EV em V + aileron", "cauda em V MH 113 invertida", "em V", 0.0),
    ("sem cauda: elevon", "EH MH 113 invertida + EV HT 14", "sem cauda", 0.0),
)


def build() -> DesignProject:
    team = DesignProject.load(SAMPLE)
    wing = team.wings[0]                                   # asa S1223
    p = DesignProject(requirements=copy.deepcopy(team.requirements), rules=copy.deepcopy(team.rules),
                      airfoils=copy.deepcopy(team.airfoils))
    p.wing_draft = copy.deepcopy(wing.params)
    p.keep_wing()
    base_plane = next(a for a in team.aircraft if a.name == "monomotor")
    for name, src, layout, pitch in OPTIONS:
        p.tail_draft = copy.deepcopy(team.set(src).params)
        p.tail_draft.name, p.tail_draft.wing, p.tail_draft.layout = name, wing.name, layout
        p.tail_draft.boom_pitch = pitch
        p.keep_set()
        p.power_draft = copy.deepcopy(base_plane.params)
        p.power_draft.name, p.power_draft.set = f"monomotor, {name.split(':')[0]}", name
        p.keep_aircraft()
    p.wing_draft = copy.deepcopy(wing.params)               # rascunhos prontos para continuar na interface
    return p


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    dst = argv[0] if argv else os.path.join(os.getcwd(), "sprint_tres_caudas")
    if os.path.abspath(dst).startswith(os.path.join(ROOT, "data") + os.sep):
        raise SystemExit("não gravo dentro de data/: escolha outra pasta")
    p = build()
    for n in store.save(p, dst):
        print(os.path.join(dst, n))
    print(f"asa: {p.wings[0].name}")
    for s, a in zip(p.sets, p.aircraft):
        print(f"  {s.name:50s} cauda {s.params.layout:12s} tubo {s.params.boom_pitch:+.0f}°  avião: {a.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
