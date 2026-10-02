"""Simulações disponíveis (uma aba cada na GUI). Para adicionar outra: crie uma classe
ISimulation num arquivo aqui e coloque-a em BUILTIN (ou registre no manager)."""
from .climb import ClimbSimulation
from .envelope import EnvelopeSimulation
from .mission import MissionSimulation
from .polar import PolarSimulation
from .takeoff import TakeoffSimulation
from .thrust import ThrustSimulation, thrust_curves
from .turn import TurnSimulation

BUILTIN = [TakeoffSimulation, TurnSimulation, EnvelopeSimulation, MissionSimulation, ClimbSimulation,
           PolarSimulation, ThrustSimulation]

__all__ = ["BUILTIN", "ClimbSimulation", "EnvelopeSimulation", "MissionSimulation", "PolarSimulation",
           "TakeoffSimulation", "ThrustSimulation", "TurnSimulation", "thrust_curves"]
