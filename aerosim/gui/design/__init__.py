"""Etapas da sprint na GUI (projeto do zero): por área, as páginas que entram antes da análise do avião
montado. A janela principal monta cada área como subabas: etapas…, "Avião montado"."""
from .pages import AirfoilPage, PowerPage, TailPage, WingPage

STAGES = {
    "aerodinamica": (("Perfil", AirfoilPage), ("Asa", WingPage)),
    "estabilidade": (("Empenagem e comandos", TailPage),),
    "desempenho": (("Motores e montagem", PowerPage),),
}
