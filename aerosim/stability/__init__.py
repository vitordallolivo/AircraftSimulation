"""Estabilidade: estática (ponto neutro, margem, volumes de cauda), gráfico tesoura
(dimensionamento da EH e da faixa de CG), dinâmica (modos do modelo linear do núcleo,
MIL-F-8785C) e dimensionamento de aileron, profundor e leme."""
from .controls import ROLL_REQ, aileron_sizing, elevator_sizing, rudder_sizing, time_to_bank
from .dynamic import lanchester, mil_check, modes, response
from .probe import Probe
from .scissor import limits, min_tail, scale_htail, scissor
from .static import analytic_np, static_analysis

__all__ = ["Probe", "ROLL_REQ", "aileron_sizing", "analytic_np", "elevator_sizing", "lanchester", "limits",
           "mil_check", "min_tail", "modes", "response", "rudder_sizing", "scale_htail", "scissor",
           "static_analysis", "time_to_bank"]
