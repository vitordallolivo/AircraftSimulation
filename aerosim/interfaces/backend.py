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
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .translator import IModelTranslator

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

    def set(self, **fields) -> None:
        """muda só alguns escalares (ex.: condições de parada) mantendo o resto da configuração"""
        raise NotImplementedError

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

    def autotune(self, V: float) -> dict[str, Any]:
        """ganhos do piloto automático pelo modelo linear em V, iguais para qualquer avião
        (núcleo: control/autotune.zig); devolve as flags (ok, pitch, roll, yaw, speed) e `gains`"""
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
    """fábrica de sessões + descrição do núcleo. `translator` leva o modelo universal
    (`aerosim.model.universal.AircraftModel`) ao SimSpec deste núcleo: as camadas de cima nunca
    montam o SimSpec à mão"""

    name: str = "backend"

    @property
    @abstractmethod
    def translator(self) -> "IModelTranslator": ...

    def session_for(self, model, mission=None, overrides: dict | None = None) -> "ISimSession":
        """sessão já configurada com o modelo universal (use com `with`)"""
        s = self.open_session()
        s.configure(self.translator.to_native(model, mission=mission, overrides=overrides))
        return s

    @abstractmethod
    def open_session(self) -> ISimSession: ...

    @abstractmethod
    def limits(self) -> dict[str, int]: ...

    @abstractmethod
    def log_channels(self) -> list[str]: ...

    def simple_performance(self, cfg: dict) -> tuple[dict, dict]:
        """desempenho por cálculo simples (sem simulação): `cfg` com W, S, C_D0, K, C_Lmax, h,
        tabela de tração (thr_V, thr_T), inclinações (bank, rad), bateria... -> (colunas por V, resumo)"""
        raise NotImplementedError(f"{self.name}: desempenho simples não implementado")

    def motor_prop_thrust(self, spec: dict, V, rho: float):
        """tração em regime de um motor + hélice + bateria com acelerador cheio em cada velocidade `V` (m/s):
        `spec` com Kv (rpm/V), Rm, B, tauc, Imax, Voc, Rint, D (m) e a tabela J, CT, CP da hélice -> array de T (N)"""
        raise NotImplementedError(f"{self.name}: tração motor + hélice não implementada")

    def local_fit(self, xs, ys, x0, r: float, quad: bool = True):
        """y ≈ a + gᵀ(x − x₀) + ½ Σ cₖ(xₖ − x₀ₖ)² por mínimos quadrados ponderados (peso (1 − (d/r)³)³, zero fora de r) nos pontos
        `xs` (m × n); sem `quad`, o plano. (g, c, a, resíduo, soma dos pesos), ou None se os pontos não determinam
        todas as direções"""
        raise NotImplementedError(f"{self.name}: modelo local não implementado")

    def sens_tolerance(self, g, c, x0, n0: float, delta):
        """a perda de nota por uma tolerância δ em cada variável, pela inclinação g e a curvatura c (NaN = sem):
        (ΔN em −δ, ΔN em +δ, elasticidade g·x/N, σ_N pelos dois primeiros momentos)"""
        raise NotImplementedError(f"{self.name}: tolerância não implementada")

    def morris_design(self, k: int, r: int, levels: int = 4, seed: int = 1):
        """as r trajetórias de Morris em [0, 1]^k, numa grade de `levels` níveis: array (r, k + 1, k)"""
        raise NotImplementedError(f"{self.name}: Morris não implementado")

    def morris_effects(self, design, y):
        """os efeitos elementares das trajetórias com as respostas y (NaN = não vale): μ, μ*, σ, passos contados"""
        raise NotImplementedError(f"{self.name}: Morris não implementado")

    def de_init(self, x0, np_: int, seed: int = 1):
        """a população inicial da evolução diferencial: `x0` em [0, 1] na primeira linha, as outras sorteadas"""
        raise NotImplementedError(f"{self.name}: evolução diferencial não implementada")

    def de_trials(self, pop, f: float = 0.7, cr: float = 0.9, seed: int = 1, generation: int = 0):
        """os testes de uma geração da evolução diferencial (DE/rand/1/bin), um por indivíduo"""
        raise NotImplementedError(f"{self.name}: evolução diferencial não implementada")

    def de_select(self, pop, fit, trials, tfit) -> int:
        """a seleção da evolução diferencial: o teste que não é pior entra no lugar (muda pop e fit)"""
        raise NotImplementedError(f"{self.name}: evolução diferencial não implementada")
