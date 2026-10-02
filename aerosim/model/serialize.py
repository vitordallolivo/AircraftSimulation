"""dataclass <-> dicionário (genérico, guiado pelas anotações de tipo)."""
from __future__ import annotations

import dataclasses
import types
import typing
from typing import Any, get_args, get_origin, get_type_hints


def to_dict(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj):
        return {f.name: to_dict(getattr(obj, f.name)) for f in dataclasses.fields(obj)}
    if isinstance(obj, (list, tuple)):
        return [to_dict(v) for v in obj]
    if isinstance(obj, dict):
        return {k: to_dict(v) for k, v in obj.items()}
    return obj


def _convert(tp, v):
    if v is None:
        return None
    origin = get_origin(tp)
    if origin in (typing.Union, types.UnionType):
        args = [a for a in get_args(tp) if a is not type(None)]
        for a in args:
            try:
                return _convert(a, v)
            except (TypeError, ValueError):
                continue
        return v
    if origin in (list, tuple):
        (arg,) = get_args(tp)[:1] or (Any,)
        return [_convert(arg, x) for x in v]
    if origin is dict:
        return dict(v)
    if dataclasses.is_dataclass(tp):
        return from_dict(tp, v)
    if tp is float:
        return float(v)
    if tp is int:
        return int(float(v))
    if tp is bool:
        if isinstance(v, str):
            return v.strip().lower() in ("1", "true", "sim", "yes", "on")
        return bool(v)
    if tp is str:
        return "" if v is None else str(v)
    return v


def from_dict(cls, data: dict):
    """cria `cls` a partir de um dicionário; chaves ausentes ficam com o padrão"""
    hints = get_type_hints(cls)
    kw = {}
    for f in dataclasses.fields(cls):
        if f.name in data:
            kw[f.name] = _convert(hints[f.name], data[f.name])
    return cls(**kw)
