"""Dimensionamento inicial (diagrama de restrições): sem núcleo e sem GUI, só as equações."""
from .constraints import (ParabolicPolar, Requirements, constraint_curves, design_point, estimate_polar,
                          required_tw)

__all__ = ["ParabolicPolar", "Requirements", "constraint_curves", "design_point", "estimate_polar", "required_tw"]
