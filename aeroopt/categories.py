"""Categorias de configuração: o tipo de avião que a busca pode montar (monoplano, biplano, tandem, asa voadora).

Cada categoria é um conjunto de campos da sprint que mudam juntos: a altura da asa (`rules.wing_z`, − = acima da
fuselagem), a segunda asa (`tail_draft.wing2`, o recuo e o desnível dela) e a cauda (`tail_draft.layout`). O
problema escolhe as categorias que valem (`params["categorias"]`), e cada uma vira um eixo a mais das configurações:
a mesma hélice, o mesmo motor, uma vez em cada categoria.

A altura da asa não é categoria: asa alta, média, baixa e parasol são o mesmo monoplano com a asa em outra altura, e
a busca já sabe mexer num número. O monoplano sai com a asa alta; para a busca escolher a altura, solta-se a variável
"altura da asa" (`rules.wing_z`, em Variáveis → regras e massas), que vale depois da categoria. Os nomes antigos
(`LEGACY`) continuam valendo, para os problemas gravados rodarem iguais.

A cauda também não é categoria: ela é escolhida pela etapa voa, a de estabilidade e controle (`stages.FlightCheck`,
com as caudas pedidas em `params["etapas"]["caudas"]`), entre convencional, em H, em V e sem cauda, para a asa de
cada configuração. Por isso "cauda em V" ficou só entre os nomes antigos. Tandem e asa voadora definem a cauda (não
têm) e ficam como estão.

    apply(projeto, "biplano")            # o projeto passa a ter duas asas iguais, uma acima da outra
"""
from __future__ import annotations

from aerosim.design import tail as tl

# campos que toda categoria define (o que não muda volta ao padrão: uma categoria não herda da outra)
_BASE = {"rules.wing_z": -0.10, "tail_draft.wing2": tl.NO_WING2, "tail_draft.wing2_dx": 0.0,
         "tail_draft.wing2_dz": 0.0, "tail_draft.wing2_di": 0.0, "tail_draft.wing2_area": 1.0,
         "tail_draft.wing2_span": 1.0, "tail_draft.wing2_sweep": 0.0, "tail_draft.wing2_airfoil": "", "tail_draft.layout": "convencional"}

CATEGORIES: dict[str, dict] = {
    "monoplano": {},                                             # asa alta; a altura sai da variável, se livre
    "biplano": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dz": 0.35},
    "tandem": {"tail_draft.wing2": tl.SAME_WING, "tail_draft.wing2_dx": 1.0, "tail_draft.wing2_dz": 0.10,
               "tail_draft.wing2_area": 2.0, "tail_draft.wing2_span": 1.5, "tail_draft.wing2_sweep": 15.0,
               "tail_draft.wing2_airfoil": "NACA 0012", "tail_draft.layout": "sem cauda"},
    "asa voadora": {"tail_draft.layout": "sem cauda"},
}
BASE_TAIL = _BASE["tail_draft.layout"]             # a categoria que fica nesta deixa a cauda para a etapa voa

# os monoplanos de antes, cada um com a sua altura de asa (problemas gravados)
LEGACY: dict[str, dict] = {
    "asa alta": {},
    "asa média": {"rules.wing_z": 0.0},
    "asa baixa": {"rules.wing_z": 0.10},
    "parasol": {"rules.wing_z": -0.30},                          # asa sobre montantes, bem acima da fuselagem
    "cauda em V": {"tail_draft.layout": "em V"},                 # a cauda agora é da etapa voa
}

# o que cada uma é e no que muda a busca (o "(?)" do menu)
HELP = {
    "monoplano": "uma asa só, com empenagem atrás. Sai com a asa alta; soltando a variável \"altura da asa\" a "
                 "busca escolhe entre alta, média, baixa e parasol. A cauda (convencional, em H, em V ou nenhuma) é "
                 "escolhida na etapa voa (E&C)",
    "biplano": "duas asas iguais, uma 35 cm acima da outra: mais área na mesma envergadura, com mais arrasto de "
               "interferência. A cauda é escolhida na etapa voa (E&C)",
    "tandem": "duas asas iguais, uma 1 m atrás da outra, sem empenagem: a de trás faz o papel da cauda",
    "asa voadora": "sem empenagem: a asa sozinha tem de equilibrar e ser estável (enflechamento, torção, perfil)",
}

KEY = "categoria"                  # o nome do eixo nas configurações


def fields(name: str) -> dict:
    """todos os campos de uma categoria (os que ela não cita ficam no padrão)"""
    known = {**CATEGORIES, **LEGACY}
    if name not in known:
        raise KeyError(f"categoria desconhecida: {name} (há {', '.join(CATEGORIES)})")
    return {**_BASE, **known[name]}



def apply(project, name: str) -> None:
    for path, v in fields(name).items():
        obj, _, attr = path.partition(".")
        setattr(getattr(project, obj), attr, v)
