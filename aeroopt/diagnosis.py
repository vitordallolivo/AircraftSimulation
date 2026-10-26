"""O diagnóstico da falha, do aeroopt: para cada motivo de um avião não voar na E&C, as variáveis que o consertam.

A E&C (`stages.FlightCheck`) já sabe por que cada ponto falha: cada termo da violação (`stages.violation_terms`)
sai com um código, como "cnb" (guina de volta devagar demais) ou "lastro" (precisa de lastro para equilibrar). A
tabela daqui liga cada código às variáveis que mexem nele, pela física de cada um: a deriva e a corda dela no
C_nβ; a posição da carga paga e o trem no equilíbrio; a decalagem e a torção no estol da asa da frente. A busca
guiada (`guided.py`) usa isso para mutar só o que conserta a falha do pai (o operador "remédio") e para tirar o
jacobiano do reparo por gradiente só nessas variáveis, que são poucas.

A tabela é uma escolha nossa, pela física de cada termo, e não um método da literatura; o que a busca faz com ela
(o reparo, o bandido) é da literatura e está em `guided.py`. Uma variável da tabela que não está livre na busca é
ignorada: sem nenhuma, o operador cai na mutação de sempre.

    d = TableDiagnosis()
    d.remedies(["cnb", "lastro"], ["tail.tip_fin", "power.x_payload", "wing.span"])
    # ['tail.tip_fin', 'power.x_payload']
"""
from __future__ import annotations

from aerosim.interfaces.optim import IFailureDiagnosis

# código do termo → as variáveis que o consertam, da que mais mexe para a que menos mexe
REMEDIES = {
    "rotacao": ("rules.de_max", "tail.elevator", "tail.aileron_chord", "power.x_tdp", "power.ground_pitch",
                "tail.sm_target"),
    "trim_picar": ("rules.de_max", "tail.sm_target", "power.tilt"),
    "trim_cl": ("tail.sm_target", "tail.wing2_di", "wing.twist", "tail.elevator", "tail.aileron_chord"),
    "nariz_subida": ("rules.de_max", "power.tilt", "tail.aileron_chord", "tail.elevator", "tail.sm_target"),
    "estol_chao": ("power.ground_pitch", "tail.wing2_di", "wing.twist"),
    "senta": ("power.x_tdp", "power.x_payload"),
    "cnb": ("tail.tip_fin", "tail.tip_fin_chord", "wing.sweep"),
    "bequilha": ("power.x_tdp", "power.x_payload"),
    "eh_estol": ("tail.sm_target", "tail.wing2_di", "tail.elevator"),
    "lastro": ("power.x_payload", "tail.sm_target"),
    "margem": ("tail.sm_target", "power.x_payload"),
    "margem_vazio": ("power.x_payload", "tail.sm_target"),
    "clb": ("wing.dihedral", "wing.sweep", "tail.tip_fin"),
    "dutch": ("tail.tip_fin", "tail.tip_fin_chord", "wing.sweep", "wing.dihedral"),
    "rolamento": ("tail.aileron_chord", "tail.aileron_start", "tail.aileron_end"),
    "espiral": ("wing.dihedral", "tail.tip_fin", "tail.tip_fin_chord"),
    "curto": ("tail.sm_target", "tail.wing2_dx", "tail.elevator"),
    "fugoide": ("tail.sm_target", "wing.twist"),
}
# o critério da MIL-F-8785C (aerosim.stability.mil_check) → o código do termo
MIL_CODES = {"ζ curto período": "curto", "ζ fugóide": "fugoide", "dutch roll ζ / ζω_n / ω_n": "dutch",
             "τ_R rolamento (s)": "rolamento", "espiral: tempo para dobrar (s)": "espiral"}


class TableDiagnosis(IFailureDiagnosis):
    """o diagnóstico pela tabela `REMEDIES`"""

    def __init__(self, table: dict | None = None):
        self.table = REMEDIES if table is None else table

    def remedies(self, codes, free) -> list[str]:
        free = list(free)
        out: list[str] = []
        for c in codes:
            out += [k for k in self.table.get(c, ()) if k in free and k not in out]
        return out
