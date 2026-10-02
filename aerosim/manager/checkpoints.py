"""Checkpoints: o estado inteiro de uma corrida num ponto (bytes do núcleo + metadados).

Os parâmetros NÃO vão junto: ao retomar, valem os da configuração nova. É assim que se
roda até um ponto, muda o que vem depois (raio de curva, ponto de soltura, ganhos...)
e continua sem refazer o que já passou.
"""
from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field


@dataclass
class Checkpoint:
    name: str
    data: bytes
    t: float
    events: dict = field(default_factory=dict)
    meta: dict = field(default_factory=dict)


class CheckpointStore:
    """dicionário thread-safe de checkpoints, com gravação opcional em disco"""

    def __init__(self, folder: str | None = None):
        self._d: dict[str, Checkpoint] = {}
        self._lock = threading.Lock()
        self.folder = folder

    def put(self, ck: Checkpoint) -> None:
        with self._lock:
            self._d[ck.name] = ck
        if self.folder:
            os.makedirs(self.folder, exist_ok=True)
            base = os.path.join(self.folder, ck.name)
            with open(base + ".ckpt", "wb") as f:
                f.write(ck.data)
            with open(base + ".json", "w") as f:
                json.dump(dict(t=ck.t, events=ck.events, meta=ck.meta), f, indent=1, default=float)

    def get(self, name: str) -> Checkpoint:
        with self._lock:
            if name in self._d:
                return self._d[name]
        if self.folder and os.path.exists(os.path.join(self.folder, name + ".ckpt")):
            base = os.path.join(self.folder, name)
            data = open(base + ".ckpt", "rb").read()
            info = json.load(open(base + ".json"))
            ck = Checkpoint(name, data, info["t"], info.get("events", {}), info.get("meta", {}))
            with self._lock:
                self._d[name] = ck
            return ck
        raise KeyError(f"checkpoint '{name}' não existe")

    def has(self, name: str) -> bool:
        try:
            self.get(name)
            return True
        except KeyError:
            return False

    def names(self) -> list[str]:
        with self._lock:
            return sorted(self._d)

    def clear(self, prefix: str = "") -> None:
        with self._lock:
            for k in [k for k in self._d if k.startswith(prefix)]:
                del self._d[k]
