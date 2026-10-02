"""Modelo de dados (independente do núcleo): aeronave, perfis, catálogo, missão, geometria."""
from .aircraft import (Aircraft, Autopilot, ControlSurface, Environment, Fuselage, GearLeg, LandingGear,
                       LiftingSurface, MassModel, Payload, PointMass, PropulsionUnit, SimSettings, SloshTank,
                       TailBoom, Takeoff, WingSection, rect_sections)
from .airfoil import Airfoil
from .catalog import Battery, Catalog, Motor, Propeller, builtin_catalog
from .compile import compile_aircraft
from .mission import Leg, Mission, MissionEvent, circuit, level_turn, takeoff_runway
from .templates import TEMPLATES
