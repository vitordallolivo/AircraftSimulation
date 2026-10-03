"""Interface da camada Sim (núcleo numérico).

O Simulation Manager só conhece estas classes; o núcleo em Zig (`aerosim.backend.zig`)
é uma implementação, e qualquer outra (um mock nos testes, outro solver) pode entrar
no lugar sem mudar o resto.

A configuração é um `SimSpec`: dicionário aninhado em SI/radianos cujas chaves são os
nomes dos campos do núcleo (`m_dry`, `surf: [ {...}, ... ]`, `ap: {...}` ...). Quem
monta o SimSpec a partir da aeronave é `aerosim.model.compile`.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any

import numpy as np

SimSpec = dict[str, Any]


class RunStatus(IntEnum):
    NOT_READY = -1
    CHUNK = 0          # chegou no t_limit pedido (pode continuar)
    STOPPED = 1        # condição de parada (stop_t, stop_seg, stop_autop)
    COMPLETED = 2      # pousou e parou / terminou a decolagem
    TIMEOUT = 3        # tmax
    CRASHED = 4        # abaixo do chão ou divergiu
    BUFFER_FULL = 5    # registro cheio (pode continuar)

    @property
    def can_continue(self) -> bool:
        return self in (RunStatus.CHUNK, RunStatus.BUFFER_FULL)


class TrimKind(IntEnum):
    LEVEL = 0
    CLIMB = 1
    GLIDE = 2
    TURN = 3


@dataclass
class LogChunk:
    """trecho do registro: uma coluna numpy por canal (SI, ângulos em rad)"""
    columns: dict[str, np.ndarray] = field(default_factory=dict)

    def __len__(self) -> int:
        return len(self.columns.get("t", ()))

    def __getitem__(self, k: str) -> np.ndarray:
        return self.columns[k]

    def __contains__(self, k: str) -> bool:
        return k in self.columns

    def keys(self):
        return self.columns.keys()

    @staticmethod
    def concat(chunks: list["LogChunk"]) -> "LogChunk":
        chunks = [c for c in chunks if len(c)]
        if not chunks:
            return LogChunk()
        ks = chunks[0].columns.keys()
        return LogChunk({k: np.concatenate([c.columns[k] for c in chunks]) for k in ks})


class ISimSession(ABC):
    """uma simulação (estado + parâmetros) dentro do núcleo"""

    @abstractmethod
    def configure(self, spec: SimSpec) -> None: ...

    @abstractmethod
    def reset_ground(self) -> None: ...

    @abstractmethod
    def reset_air(self, segment: int) -> None: ...

    @abstractmethod
    def run(self, t_limit: float = float("inf"), max_rows: int = 200_000) -> tuple[RunStatus, LogChunk]:
        """avança até parar, até t_limit ou até registrar max_rows linhas (0: sem registro)"""

    @abstractmethod
    def events(self) -> dict[str, float]: ...

    @property
    @abstractmethod
    def time(self) -> float: ...

    @abstractmethod
    def snapshot(self) -> bytes: ...

    @abstractmethod
    def restore(self, snap: bytes) -> None: ...

    @abstractmethod
    def aero_coeffs(self, V: float, alpha: float, beta: float = 0.0,
                    de: float = 0.0, da: float = 0.0, dr: float = 0.0) -> dict[str, float]: ...

    def aero_coeffs_ex(self, V: float, alpha: float, beta: float = 0.0, p: float = 0.0, q: float = 0.0,
                       r: float = 0.0, de: float = 0.0, da: float = 0.0, dr: float = 0.0,
                       ref: list[float] | None = None) -> dict[str, float]:
        """coeficientes com rotação (rad/s) e momentos no ponto `ref` do corpo (None: CG)"""
        raise NotImplementedError

    def linearize(self, V: float) -> dict[str, Any]:
        """equilíbrio nivelado em V e modelo linear: A (8×8) sobre (u, v, w, p, q, r, φ, θ),
        B (8×4) sobre (δe, δa, δr, acelerador), mais o ponto (alpha, de, thr, phi, da, dr, m, I, cg, ok)"""
        raise NotImplementedError

    @abstractmethod
    def prop_point(self, index: int, V: float, thr: float = 1.0) -> dict[str, float]: ...

    @abstractmethod
    def mass_props(self) -> dict[str, Any]: ...

    @abstractmethod
    def trim(self, kind: TrimKind, V: float, n: float = 1.0) -> dict[str, float]: ...

    @abstractmethod
    def performance(self, V_hi: float, V_lo: float, dV: float) -> dict[str, np.ndarray]: ...

    def envelope(self, cfg: dict) -> tuple[dict[str, np.ndarray], float]:
        """envelope por altitude: colunas (h, rho, Vmin, Vmax, Ve, Vman, Vcru, Td_max) e o teto"""
        raise NotImplementedError

    def envelope_curve(self, cfg: dict, h: float, n: int = 200) -> dict[str, np.ndarray]:
        """T_d(V) e T_r(V) numa altitude"""
        raise NotImplementedError

    @abstractmethod
    def derived(self) -> SimSpec:
        """parâmetros como o núcleo os vê depois de `configure` (com os derivados)"""

    @abstractmethod
    def close(self) -> None: ...

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class ISimBackend(ABC):
    """fábrica de sessões + descrição do núcleo"""

    name: str = "backend"

    @abstractmethod
    def open_session(self) -> ISimSession: ...

    @abstractmethod
    def limits(self) -> dict[str, int]: ...

    @abstractmethod
    def log_channels(self) -> list[str]: ...
