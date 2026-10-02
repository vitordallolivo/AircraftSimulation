"""aerosim — simulador 6GDL de aeronaves em camadas:

    GUI (aerosim.gui) -> Simulation Manager (aerosim.manager) -> Sim (aerosim.backend / core/ em Zig)
    Aircraft Data (aerosim.data) alimenta o modelo (aerosim.model)

Cada camada fala com a outra só por interfaces (aerosim.interfaces).
"""
__version__ = "0.2.0"
