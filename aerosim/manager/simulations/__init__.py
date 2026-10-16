"""Simulações disponíveis (uma aba cada na GUI). Para adicionar outra: crie uma classe
ISimulation num arquivo aqui e coloque-a em BUILTIN (ou registre no manager)."""
from .aerodynamics import AerodynamicsSimulation
from .climb import ClimbSimulation
from .envelope import EnvelopeSimulation
from .loads import LoadsSimulation
from .mission import MissionSimulation
from .performance import PerformanceSimulation
from .polar import PolarSimulation
from .sizing import SizingSimulation
from .stability import StabilitySimulation
from .takeoff import TakeoffSimulation
from .thrust import ThrustSimulation, thrust_curves
from .turn import TurnSimulation

# abas: decolagem, curvas simuladas e subida simulada são modos da Missão; envelope, subida,
# descida e curva por cálculo estão no Desempenho; a polar da aeronave está na Aerodinâmica.
# As classes antigas continuam importáveis (scripts e testes).
BUILTIN = [SizingSimulation, MissionSimulation, PerformanceSimulation, ThrustSimulation, AerodynamicsSimulation,
           StabilitySimulation, LoadsSimulation, TakeoffSimulation, TurnSimulation, EnvelopeSimulation, ClimbSimulation,
           PolarSimulation]

__all__ = ["BUILTIN", "SizingSimulation", "AerodynamicsSimulation", "ClimbSimulation", "EnvelopeSimulation", "LoadsSimulation", "MissionSimulation", "PerformanceSimulation", "PolarSimulation",
           "TakeoffSimulation", "ThrustSimulation", "TurnSimulation", "thrust_curves"]
