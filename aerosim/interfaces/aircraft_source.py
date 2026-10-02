"""Interface "Aircraft Data": de onde vem (e para onde vai) a aeronave.

Implementações em `aerosim.data`: .cfg (INI), .xlsx (Excel), .json. A GUI e o
Simulation Manager só usam estas interfaces, então trocar a origem dos dados é trocar
o objeto passado, nada mais.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from aerosim.model.aircraft import Aircraft
    from aerosim.model.catalog import Catalog


class IAircraftSource(ABC):
    """lê e grava uma aeronave completa"""

    extensions: tuple[str, ...] = ()

    @abstractmethod
    def load(self, path: str) -> "Aircraft": ...

    @abstractmethod
    def save(self, aircraft: "Aircraft", path: str) -> None: ...


class ICatalogSource(ABC):
    """lê e grava um catálogo de motores, hélices e baterias"""

    extensions: tuple[str, ...] = ()

    @abstractmethod
    def load_catalog(self, path: str) -> "Catalog": ...

    @abstractmethod
    def save_catalog(self, catalog: "Catalog", path: str) -> None: ...
