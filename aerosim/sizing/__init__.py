"""Dimensionamento inicial (diagrama de restrições): sem núcleo e sem GUI, só as equações."""
from .constraints import AeroModel, Requirements, constraint_curves, design_point, required_tw

__all__ = ["AeroModel", "Requirements", "constraint_curves", "design_point", "required_tw"]
