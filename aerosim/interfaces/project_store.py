"""Interface da biblioteca de aeronaves do usuário ("meus aviões").

Cada aeronave é salva com o nome que o usuário der; salvar de novo com o mesmo nome
atualiza, com outro nome cria uma nova. A GUI só conhece esta interface; a implementação
em `aerosim.data.projects` grava um .json por aeronave numa pasta.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from aerosim.model.aircraft import Aircraft


@dataclass
class ProjectInfo:
    name: str
    path: str
    saved: str            # data e hora (ISO)
    summary: str = ""     # S, b, massa, configuração


class IProjectStore(ABC):
    root: str = ""

    @abstractmethod
    def list(self) -> list[ProjectInfo]: ...

    @abstractmethod
    def exists(self, name: str) -> bool: ...

    @abstractmethod
    def save(self, aircraft: "Aircraft", name: str | None = None) -> ProjectInfo:
        """grava com `name` (ou o nome da aeronave); o nome da aeronave passa a ser esse"""

    @abstractmethod
    def load(self, name: str) -> "Aircraft": ...

    @abstractmethod
    def delete(self, name: str) -> None: ...
