"""Categorias de configuração: o tipo de avião que a busca pode montar (monoplano, biplano, tandem, asa voadora,
cauda em V).

Cada categoria é um conjunto de campos da sprint que mudam juntos: a altura da asa (`rules.wing_z`, − = acima da
fuselagem), a segunda asa (`tail_draft.wing2`, o recuo e o desnível dela) e a cauda (`tail_draft.layout`). O
problema escolhe as categorias que valem (`params["categorias"]`), e cada uma vira um eixo a mais das configurações:
a mesma hélice, o mesmo motor, uma vez em cada categoria.

A altura da asa não é categoria: asa alta, média, baixa e parasol são o mesmo monoplano com a asa em outra altura, e
a busca já sabe mexer num número. O monoplano sai com a asa alta; para a busca escolher a altura, solta-se a variável
"altura da asa" (`rules.wing_z`, em Variáveis → regras e massas), que vale depois da categoria. Os nomes antigos
(`LEGACY`) continuam valendo, para os problemas gravados rodarem iguais.

    apply(projeto, "biplano")            # o projeto passa a ter duas asas iguais, uma acima da outra
"""
from __future__ import annotations

from aerosim.design import tail as tl

# campos que toda categoria define (o que não muda volta ao padrão: uma categoria não herda da outra)
_BASE = {"rules.wing_z": -0.10, "tail_draft.wing2": tl.NO_WING2, "tail_draft.wing2_dx": 0.0,
         "tail_draft.wing2_dz": 0.0, "tail_draft.wing2_di": 0.0, "tail_draft.layout": "convencional"}

CATEGORIES: dict[str, dict] = {
    "monoplano": {},                                             # asa alta; a altura sai da variável, se livre
    "biplano": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dz": 0.35},
    "tandem": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dx": 1.0, "tail_draft.wing2_dz": 0.10,
               "tail_draft.layout": "sem cauda"},
    "asa voadora": {"tail_draft.layout": "sem cauda"},
    "cauda em V": {"tail_draft.layout": "em V"},
}

# os monoplanos de antes, cada um com a sua altura de asa (problemas gravados)
LEGACY: dict[str, dict] = {
    "asa alta": {},
    "asa média": {"rules.wing_z": 0.0},
    "asa baixa": {"rules.wing_z": 0.10},
    "parasol": {"rules.wing_z": -0.30},                          # asa sobre montantes, bem acima da fuselagem
}

# o que cada uma é e no que muda a busca (o "(?)" do menu)
HELP = {
    "monoplano": "uma asa só, com empenagem convencional atrás. Sai com a asa alta; soltando a variável "
                 "\"altura da asa\" a busca escolhe entre alta, média, baixa e parasol",
    "biplano": "duas asas iguais, uma 35 cm acima da outra: mais área na mesma envergadura, com mais arrasto de "
               "interferência",
    "tandem": "duas asas iguais, uma 1 m atrás da outra, sem empenagem: a de trás faz o papel da cauda",
    "asa voadora": "sem empenagem: a asa sozinha tem de equilibrar e ser estável (enflechamento, torção, perfil)",
    "cauda em V": "monoplano com duas superfícies em V no lugar da horizontal e da vertical",
}

KEY = "categoria"                  # o nome do eixo nas configurações


def fields(name: str) -> dict:
    """todos os campos de uma categoria (os que ela não cita ficam no padrão)"""
    known = {**CATEGORIES, **LEGACY}
    if name not in known:
        raise KeyError(f"categoria desconhecida: {name} (há {', '.join(CATEGORIES)})")
    return {**_BASE, **known[name]}


def current(name: str) -> str:
    """o nome de hoje de uma categoria (os monoplanos antigos viram "monoplano")"""
    return "monoplano" if name in LEGACY else name


def apply(project, name: str) -> None:
    for path, v in fields(name).items():
        obj, _, attr = path.partition(".")
        setattr(getattr(project, obj), attr, v)
