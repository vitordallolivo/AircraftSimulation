"""Categorias de configuração: o tipo de avião que a busca pode montar (asa alta, baixa, parasol, biplano, tandem,
asa voadora, cauda em V).

Cada categoria é um conjunto de campos da sprint que mudam juntos: a altura da asa (`rules.wing_z`, − = acima da
fuselagem), a segunda asa (`tail_draft.wing2`, o recuo e o desnível dela) e a cauda (`tail_draft.layout`). O
problema escolhe as categorias que valem (`params["categorias"]`), e cada uma vira um eixo a mais das configurações:
a mesma hélice, o mesmo motor, uma vez em cada categoria.

    apply(projeto, "biplano")            # o projeto passa a ter duas asas iguais, uma acima da outra
"""
from __future__ import annotations

from aerosim.design import tail as tl

# campos que toda categoria define (o que não muda volta ao padrão: uma categoria não herda da outra)
_BASE = {"rules.wing_z": -0.10, "tail_draft.wing2": tl.NO_WING2, "tail_draft.wing2_dx": 0.0,
         "tail_draft.wing2_dz": 0.0, "tail_draft.wing2_di": 0.0, "tail_draft.layout": "convencional"}

CATEGORIES: dict[str, dict] = {
    "asa alta": {},
    "asa média": {"rules.wing_z": 0.0},
    "asa baixa": {"rules.wing_z": 0.10},
    "parasol": {"rules.wing_z": -0.30},                          # asa sobre montantes, bem acima da fuselagem
    "biplano": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dz": 0.35},
    "tandem": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dx": 1.0, "tail_draft.wing2_dz": 0.10,
               "tail_draft.layout": "sem cauda"},
    "asa voadora": {"tail_draft.layout": "sem cauda"},
    "cauda em V": {"tail_draft.layout": "em V"},
}

KEY = "categoria"                  # o nome do eixo nas configurações


def fields(name: str) -> dict:
    """todos os campos de uma categoria (os que ela não cita ficam no padrão)"""
    if name not in CATEGORIES:
        raise KeyError(f"categoria desconhecida: {name} (há {', '.join(CATEGORIES)})")
    return {**_BASE, **CATEGORIES[name]}


def apply(project, name: str) -> None:
    for path, v in fields(name).items():
        obj, _, attr = path.partition(".")
        setattr(getattr(project, obj), attr, v)
