"""O formulário de uma dataclass em `ParamSpec`, sem Qt: a mesma leitura que `DataclassForm`
(`aerosim/gui/widgets/param_slider.py`) faz dos campos, para a tela em Zig desenhar o rascunho de uma etapa.

Rótulo, unidade, dica, opções e faixa vêm dos metadados do campo (`aerosim.design.fields.F`) ou, sem eles, dos
dicionários de `form_meta`. Uma dataclass dentro de outra vira um grupo, com as chaves em caminho ("airfoil.cl_max").
Um número opcional (`float | None`) vira um marcador "auto" (chave terminada em `AUTO`) mais o número. Listas ficam
de fora, como no formulário da GUI PyQt (elas têm editores próprios).
"""
from __future__ import annotations

import dataclasses
import types
import typing

from aerosim.interfaces.simulation import ParamSpec

from .form_meta import CHOICES, HELP, LABELS, RANGES, UNITS

AUTO = "?auto"          # sufixo da chave do marcador "auto" de um número opcional


def specs(obj, exclude: tuple = (), choices: dict | None = None, editable: tuple = (), group: str = "",
          prefix: str = "") -> list[ParamSpec]:
    """os campos de `obj` como `ParamSpec` (na ordem da dataclass); `choices` manda sobre os metadados"""
    given = dict(choices or {})
    hints = typing.get_type_hints(type(obj))
    out: list[ParamSpec] = []
    for f in dataclasses.fields(obj):
        if f.name in exclude:
            continue
        out += _field(obj, f, hints[f.name], given, set(editable), group, prefix)
    return out


def _field(obj, f, tp, given: dict, editable: set, group: str, prefix: str) -> list[ParamSpec]:
    name, value, meta = f.name, getattr(obj, f.name), dict(f.metadata)
    key = prefix + name
    label = meta.get("label") or LABELS.get(name, name)
    help = meta.get("help") or HELP.get(name, "")
    optional = typing.get_origin(tp) in (typing.Union, types.UnionType)
    base = [a for a in typing.get_args(tp) if a is not type(None)][0] if optional else tp
    if dataclasses.is_dataclass(base):
        if value is None:
            return []
        return specs(value, exclude=("coords",), choices=given, group=label, prefix=key + ".")
    if base is bool:
        return [ParamSpec(key, label, bool(value), kind="bool", help=help, group=group)]
    if base is str:
        options = given.get(name) or meta.get("choices") or CHOICES.get(name)
        if options:
            options = tuple(str(o) for o in options)
            if value not in options and (name in editable or value):
                options = options + (str(value),)      # texto livre ou valor que saiu da lista: fica como opção
            return [ParamSpec(key, label, str(value), kind="choice", choices=options, help=help, group=group)]
        return [ParamSpec(key, label, str(value), kind="str", help=help, group=group)]
    if base is int:
        return [ParamSpec(key, label, int(value), kind="int", help=help, group=group)]
    if base is float:
        low, high, step, unit = RANGES.get(name, (None, None, None, UNITS.get(name, "")))
        low = high = None                              # a faixa do slider não é limite do valor
        if "range" in meta:
            low, high, step = meta["range"][0], meta["range"][1], meta["range"][2] or step
        if "label" in meta:
            unit = meta.get("unit", "")
        number = ParamSpec(key, label, 0.0 if value is None else float(value), minimum=low, maximum=high, step=step,
                           unit=unit, help=help, group=group)
        if optional:
            return [ParamSpec(key + AUTO, f"{label}: auto", value is None, kind="bool", help=help, group=group),
                    number]
        return [number]
    return []


def apply(obj, values: dict) -> list[str]:
    """grava os valores (chaves em caminho, como as de `specs`) em `obj`; devolve as chaves que mudaram"""
    changed = []
    autos = {k[:-len(AUTO)]: bool(v) for k, v in values.items() if k.endswith(AUTO)}
    for key, value in values.items():
        if key.endswith(AUTO):
            continue
        *path, name = key.split(".")
        target = obj
        for part in path:
            target = getattr(target, part, None)
            if target is None:
                break
        if target is None or not hasattr(target, name):
            continue
        old = getattr(target, name)
        if autos.get(key):
            new = None
        elif isinstance(old, bool):
            new = bool(value)
        elif isinstance(old, int) and not isinstance(old, bool):
            new = int(round(float(value)))
        elif isinstance(old, float) or (old is None and key in autos):
            new = float(value)
        elif isinstance(old, str):
            new = str(value)
        else:
            continue
        if new != old:
            setattr(target, name, new)
            changed.append(key)
    return changed
