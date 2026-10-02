"""Aeronave <-> seções planas (usado pelos formatos .cfg e .xlsx).

    seção "aircraft"                 escalares da raiz
    seção "fuselage", "gear", ...    cada dataclass filha da raiz
    seção "surfaces.0"               item 0 de uma lista de dataclasses
    seção "surfaces.0.sections.1"    listas dentro de itens
    chave "airfoil.name"             dataclass aninhada dentro de um item (em linha)
"""
from __future__ import annotations

import dataclasses
import json
import re
from typing import Any

SKIP = {"coords"}          # contorno do perfil: vem do .dat


def _is_dc(v) -> bool:
    return dataclasses.is_dataclass(v) and not isinstance(v, type)


def _inline(obj, prefix: str, sec: dict, out: dict, section: str) -> None:
    for f in dataclasses.fields(obj):
        if f.name in SKIP:
            continue
        v = getattr(obj, f.name)
        key = prefix + f.name
        if _is_dc(v):
            _inline(v, key + ".", sec, out, section)
        elif isinstance(v, list) and v and _is_dc(v[0]):
            for i, item in enumerate(v):
                flatten(item, f"{section}.{key}.{i}", out)
        else:
            sec[key] = v


def flatten(obj, section: str = "aircraft", out: dict | None = None, root: bool = True) -> dict[str, dict]:
    out = {} if out is None else out
    sec = out.setdefault(section, {})
    for f in dataclasses.fields(obj):
        if f.name in SKIP:
            continue
        v = getattr(obj, f.name)
        if _is_dc(v):
            if root and section == "aircraft":
                flatten(v, f.name, out, root=False)
            else:
                _inline(v, f.name + ".", sec, out, section)
        elif isinstance(v, list) and v and _is_dc(v[0]):
            base = f.name if (root and section == "aircraft") else f"{section}.{f.name}"
            for i, item in enumerate(v):
                flatten(item, f"{base}.{i}", out, root=False)
        else:
            sec[f.name] = v
    return out


def _set(d: dict, path: list, value) -> None:
    for p in path[:-1]:
        d = d.setdefault(p, {})
    d[path[-1]] = value


def _listify(x):
    if isinstance(x, dict):
        if x and all(isinstance(k, int) for k in x):
            return [_listify(x[k]) for k in sorted(x)]
        return {k: _listify(v) for k, v in x.items()}
    return x


def unflatten(sections: dict[str, dict]) -> dict:
    tree: dict = {}
    for name, keys in sections.items():
        path = [] if name == "aircraft" else [int(p) if p.isdigit() else p for p in name.split(".")]
        for k, v in keys.items():
            _set(tree, path + k.split("."), v)
    return _listify(tree)


# ------------------------------------------------------------------ valores em texto
_NUMLIKE = re.compile(r"^\s*(-?\d|\[|\{|true$|false$|null$|\")")


def encode(v: Any) -> str:
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False) if (_NUMLIKE.match(v) or v == "" or v != v.strip()) else v
    return json.dumps(v, ensure_ascii=False)


def decode(s: str) -> Any:
    s = s.strip()
    try:
        return json.loads(s)
    except (ValueError, TypeError):
        return s
