"""Contrato de quem roda uma função em muitos itens independentes: em série, em linhas de execução (threads) ou em
processos. Quem precisa de paralelismo (o processo em etapas do aeroopt, as gerações, as ferramentas de medida)
depende só daqui; a forma de rodar é escolhida fora e pode durar uma rodada inteira, sem nascer de novo a cada lote.

    with make_executor("processos", workers=4, start_method="spawn") as ex:     # aerosim.parallel
        for lote in lotes:
            res = ex.map(conta, lote, cancel=parar.is_set, on_done=lambda j, r: print(j, r.ok))

`map` guarda a ordem dos itens: o resultado não depende de quem terminou primeiro. Cada item vira um `Outcome`
(o valor, ou o erro que a conta levantou, ou "cancelado"); um item que quebra não derruba os outros.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

KINDS = ("não", "threads", "processos")       # "não": em série, na linha de quem chama


@dataclass
class Outcome:
    value: Any = None
    error: BaseException | None = None
    cancelled: bool = False

    @property
    def ok(self) -> bool:
        return self.error is None and not self.cancelled


class IExecutor(ABC):
    kind: str = "não"                         # um de KINDS
    workers: int = 1

    @abstractmethod
    def map(self, fn: Callable[[Any], Any], items: Sequence[Any], cancel: Callable[[], bool] | None = None,
            on_done: Callable[[int, Outcome], None] | None = None) -> list[Outcome]:
        """`fn(item)` em cada item; `on_done(j, resultado)` na linha de quem chama, na ordem em que terminam.
        `cancel()` é visto em uma fração de segundo: o que não terminou volta com `cancelled = True`.
        Em processos, `fn` e os itens têm de poder ir por pickle (uma função de módulo ou um método de um objeto
        que vai por pickle)"""

    def close(self) -> None:
        """solta as linhas ou os processos (o executor pode voltar a ser usado: eles nascem de novo)"""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
