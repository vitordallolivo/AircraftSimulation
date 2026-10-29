"""Etapas da sprint na GUI (projeto do zero): por área, as páginas que entram antes da análise do avião
montado. A janela principal monta cada área como subabas: etapas…, "Avião montado" (na Aerodinâmica, "Analisar")."""
from .mdo_page import MdoPage
from .pages import AirfoilPage, PowerPage, StudyPage, TailPage, WingPage

# a última subaba (a simulação de sempre da área) — "Avião montado", salvo quando o nome diz outra coisa
LAST_TAB = {"dimensionamento": "Diagrama de restrições", "aerodinamica": "Analisar"}
# o nome da aba da área, quando ele não é o título da simulação dela (a Aerodinâmica roda a simulação "Asas", na subaba Analisar)
AREA_TAB = {"aerodinamica": "Aerodinâmica"}

STAGES = {
    "dimensionamento": (("Mini-MDO (otimizador)", MdoPage),),
    "aerodinamica": (("Perfis", AirfoilPage), ("Projetar", WingPage)),
    "estabilidade": (("Empenagem e comandos", TailPage),),
    "desempenho": (("Motores e montagem", PowerPage), ("Estudo e ponto de projeto", StudyPage)),
}
