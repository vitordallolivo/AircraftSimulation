"""Campo de dataclass com o que a GUI precisa para mostrá-lo (rótulo, unidade, dica, opções, faixa).

    span: float = F(2.4, "envergadura", "m", "de ponta a ponta", lo=0.3, hi=6)

`DataclassForm` (gui/widgets/param_slider.py) lê esses metadados; sem eles cai nos dicionários globais.
"""
from __future__ import annotations

from dataclasses import field


def F(default, label: str, unit: str = "", help: str = "", lo: float | None = None, hi: float | None = None,
      step: float | None = None, *, choices: tuple | None = None):
    meta = dict(label=label, unit=unit, help=help)
    if choices:
        meta["choices"] = tuple(choices)
    if lo is not None or hi is not None or step is not None:
        meta["range"] = (lo, hi, step)
    if isinstance(default, (list, dict)):
        return field(default_factory=lambda d=default: type(d)(d), metadata=meta)
    return field(default=default, metadata=meta)
