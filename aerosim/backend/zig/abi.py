"""Monta as estruturas ctypes a partir do esquema que o núcleo Zig exporta.

Nenhum layout é escrito à mão aqui: `aerosim_schema()` descreve cada struct (campos,
tipos, contagens, offsets) e este módulo cria as classes ctypes e confere tamanho e
offsets de cada campo. Se o núcleo mudar, o Python acompanha sozinho.
"""
from __future__ import annotations

import ctypes
from dataclasses import dataclass, field

import numpy as np

_PRIM = {"f64": ctypes.c_double, "i32": ctypes.c_int32}

# as structs que o Python usa pelo nome: se faltar alguma, a biblioteca é de outra versão do núcleo
REQUIRED = ("AeroCoeffs", "EnvCfg", "EnvRow", "Events", "Individual", "LinModel", "LinSloshModel", "LogRow", "MassProps", "OptOpts",
            "Params", "PerfRow", "PropPoint", "Result", "SimpleCfg", "SimpleRow", "SimpleSummary", "SizingCfg",
            "SizingOut", "TrimPoint")


class AbiMismatch(RuntimeError):
    """a biblioteca carregada não é a dos fontes atuais do núcleo (recompile: python -m aerosim.backend.zig)"""


def fnv1a64(data: bytes) -> int:
    """o mesmo hash que o núcleo calcula em comptime (`abi.schema_hash`)"""
    h = 0xcbf29ce484222325
    for c in data:
        h ^= c
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def check(sc: "Schema", text: bytes, lib_hash: int | None, required=REQUIRED) -> None:
    """o esquema chegou inteiro e tem tudo o que o Python usa; senão AbiMismatch com o que falta"""
    if lib_hash is not None and fnv1a64(text) != lib_hash:
        raise AbiMismatch(f"esquema do núcleo corrompido (hash {fnv1a64(text):016x} ≠ {lib_hash:016x})")
    missing = [n for n in required if n not in sc.structs]
    if missing:
        raise AbiMismatch("a biblioteca do núcleo não tem " + ", ".join(missing) +
                          ": ela é de outra versão dos fontes (apague core/zig-out e rode de novo)")
_NP = {"f64": np.float64, "i32": np.int32}


@dataclass
class FieldInfo:
    name: str
    kind: str
    count: int
    offset: int


@dataclass
class StructInfo:
    name: str
    size: int
    align: int
    fields: list[FieldInfo] = field(default_factory=list)


@dataclass
class Schema:
    abi: int = 0
    hash: int = 0                       # FNV-1a 64 do texto (o mesmo de aerosim_schema_hash)
    limits: dict[str, int] = field(default_factory=dict)
    snapshot_size: int = 0
    poly_terms: list[str] = field(default_factory=list)   # ordem dos coeficientes do polinômio de tração
    structs: dict[str, StructInfo] = field(default_factory=dict)
    types: dict[str, type] = field(default_factory=dict)       # ctypes
    dtypes: dict[str, np.dtype] = field(default_factory=dict)  # numpy (structs planas)


def parse(text: str) -> Schema:
    sc = Schema(hash=fnv1a64(text.encode()))
    cur: StructInfo | None = None
    for line in text.splitlines():
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "abi":
            sc.abi = int(tok[1])
        elif tok[0] == "limit":
            sc.limits[tok[1]] = int(tok[2])
        elif tok[0] == "poly_terms":
            sc.poly_terms = tok[1:]
        elif tok[0] == "snapshot":
            sc.snapshot_size = int(tok[1])
        elif tok[0] == "struct":
            cur = StructInfo(tok[1], int(tok[2]), int(tok[3]))
        elif tok[0] == "field":
            assert cur is not None
            cur.fields.append(FieldInfo(tok[1], tok[2], int(tok[3]), int(tok[4])))
        elif tok[0] == "end":
            assert cur is not None
            sc.structs[cur.name] = cur
            cur = None
    for name, st in sc.structs.items():
        sc.types[name] = _build(sc, st)
        if all(f.kind in _PRIM for f in st.fields):
            sc.dtypes[name] = np.dtype({
                "names": [f.name for f in st.fields],
                "formats": [(_NP[f.kind], (f.count,)) if f.count > 1 else _NP[f.kind] for f in st.fields],
                "offsets": [f.offset for f in st.fields],
                "itemsize": st.size,
            })
    return sc


def _build(sc: Schema, st: StructInfo) -> type:
    fields = []
    for f in st.fields:
        base = _PRIM.get(f.kind) or sc.types[f.kind]
        fields.append((f.name, base * f.count if f.count > 1 else base))
    cls = type(st.name, (ctypes.Structure,), {"_fields_": fields})
    if ctypes.sizeof(cls) != st.size:
        raise RuntimeError(f"ABI: {st.name} tem {ctypes.sizeof(cls)} bytes no Python e {st.size} no núcleo")
    for f in st.fields:
        off = getattr(cls, f.name).offset
        if off != f.offset:
            raise RuntimeError(f"ABI: {st.name}.{f.name} offset {off} != {f.offset}")
    return cls


# ------------------------------------------------------------- dicionário <-> struct
def _is_struct(v) -> bool:
    return isinstance(v, ctypes.Structure)


def write(obj: ctypes.Structure, spec: dict, path: str = "") -> None:
    """escreve um SimSpec (dicionário aninhado) na struct; chave desconhecida é erro"""
    names = {n for n, _ in obj._fields_}
    for k, v in spec.items():
        if k not in names:
            raise KeyError(f"campo desconhecido no núcleo: {path}{k}")
        cur = getattr(obj, k)
        if _is_struct(cur):
            write(cur, v, f"{path}{k}.")
        elif isinstance(cur, ctypes.Array):
            if len(cur) and _is_struct(cur[0]):
                if len(v) > len(cur):
                    raise ValueError(f"{path}{k}: {len(v)} itens, limite {len(cur)}")
                for i, item in enumerate(v):
                    write(cur[i], item, f"{path}{k}[{i}].")
            else:
                vals = list(v) if hasattr(v, "__len__") else [v]
                if len(vals) > len(cur):
                    raise ValueError(f"{path}{k}: {len(vals)} valores, limite {len(cur)}")
                cur[:len(vals)] = [float(x) if isinstance(cur[0], float) else int(x) for x in vals]
        else:
            setattr(obj, k, type(cur)(v) if isinstance(cur, int) else float(v))


def read(obj) -> dict:
    """struct -> dicionário (arrays viram listas)"""
    out = {}
    for k, _ in obj._fields_:
        v = getattr(obj, k)
        if _is_struct(v):
            out[k] = read(v)
        elif isinstance(v, ctypes.Array):
            out[k] = [read(x) for x in v] if len(v) and _is_struct(v[0]) else list(v)
        else:
            out[k] = v
    return out
