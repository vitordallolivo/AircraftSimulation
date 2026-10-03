"""Dimensionamento inicial (diagrama de restrições): sem núcleo e sem GUI, só as equações."""
from .constraints import ParabolicPolar, Requirements, constraint_curves, design_point, required_tw

__all__ = ["ParabolicPolar", "Requirements", "constraint_curves", "design_point", "required_tw"]
