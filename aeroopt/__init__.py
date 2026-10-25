"""aeroopt: o otimizador do projeto (MDO). Monta um problema a partir de peças trocáveis (variáveis, restrições,
pontuação, avaliador, solver) e avalia cada candidato no núcleo. Os contratos estão em
`aerosim/interfaces/optim.py`; o README desta pasta explica como usar."""
from .problem import apply_to_project, from_project, load, save

__all__ = ["apply_to_project", "from_project", "load", "save"]
