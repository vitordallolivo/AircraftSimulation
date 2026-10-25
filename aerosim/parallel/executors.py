"""As três formas de rodar uma função em muitos itens (`aerosim.interfaces.executor.IExecutor`).

Em série, a conta roda na linha de quem chama. Em linhas de execução, todas dividem o GIL: só ganha a parte que
passa no núcleo (as chamadas por ctypes soltam o GIL). Em processos, cada trabalhador tem o seu Python e o seu
núcleo, então não há GIL a dividir, mas nascer custa (o spawn importa tudo de novo) e cada item vai e volta por
pickle. Por isso o executor de processos guarda os trabalhadores entre um `map` e o próximo: numa rodada de
várias etapas e várias gerações, eles nascem uma vez.
"""
from __future__ import annotations

import os
from collections.abc import Callable, Sequence
from concurrent.futures import (FIRST_COMPLETED, BrokenExecutor, Executor, ProcessPoolExecutor, ThreadPoolExecutor,
                                wait)
from typing import Any

from aerosim.interfaces.executor import KINDS, IExecutor, Outcome

POLL = 0.2              # s: de quanto em quanto o `cancel` é olhado enquanto os trabalhadores contam


def default_workers() -> int:
    return max(1, os.cpu_count() or 1)


class SerialExecutor(IExecutor):
    kind = "não"

    def __init__(self, workers: int | None = None):
        self.workers = 1

    def map(self, fn, items, cancel=None, on_done=None) -> list[Outcome]:
        out = []
        for j, it in enumerate(items):
            if cancel is not None and cancel():
                r = Outcome(cancelled=True)
            else:
                try:
                    r = Outcome(fn(it))
                except Exception as e:  # noqa: BLE001 — um item que quebra para ali; os outros seguem
                    r = Outcome(error=e)
            out.append(r)
            if not r.cancelled and on_done:
                on_done(j, r)
        return out


class _PoolExecutor(IExecutor):
    """o que linhas e processos têm em comum: um `concurrent.futures.Executor` guardado entre os `map`"""

    def __init__(self, workers: int | None = None):
        self.workers = max(1, int(workers or default_workers()))
        self._pool: Executor | None = None

    def _new_pool(self) -> Executor:
        raise NotImplementedError

    def start(self) -> None:
        """abre o pool já (senão ele abre no primeiro `map`): para medir quanto custa nascer à parte"""
        if self._pool is None:
            self._pool = self._new_pool()

    def _stop(self) -> None:
        """o Parar no meio: solta o pool sem esperar a conta que está rodando"""
        if self._pool is not None:
            self._pool.shutdown(wait=False, cancel_futures=True)
            self._pool = None

    def map(self, fn: Callable[[Any], Any], items: Sequence[Any], cancel=None, on_done=None) -> list[Outcome]:
        items = list(items)
        if len(items) < 2 or self.workers == 1:      # um item só não paga a ida e a volta
            return SerialExecutor().map(fn, items, cancel, on_done)
        self.start()
        out: list[Outcome | None] = [None] * len(items)
        futs = {self._pool.submit(fn, it): j for j, it in enumerate(items)}
        pending = set(futs)
        stopped = broken = False
        try:
            while pending:
                # espera pouco por vez: o Parar é visto em uma fração de segundo, não quando o próximo termina
                done, pending = wait(pending, timeout=POLL, return_when=FIRST_COMPLETED)
                for f in done:
                    j = futs[f]
                    try:
                        out[j] = Outcome(f.result())
                    except Exception as e:  # noqa: BLE001
                        out[j] = Outcome(error=e)
                        broken = broken or isinstance(e, BrokenExecutor)
                    if on_done:
                        on_done(j, out[j])
                if cancel is not None and cancel():
                    stopped = True
                    break
        finally:
            if stopped or broken:
                self._stop()
        return [o if o is not None else Outcome(cancelled=True) for o in out]

    def close(self) -> None:
        if self._pool is not None:
            self._pool.shutdown(wait=True, cancel_futures=True)
            self._pool = None


class ThreadExecutor(_PoolExecutor):
    kind = "threads"

    def _new_pool(self) -> Executor:
        return ThreadPoolExecutor(max_workers=self.workers)


class ProcessExecutor(_PoolExecutor):
    kind = "processos"

    def __init__(self, workers: int | None = None, start_method: str | None = None,
                 initializer: Callable[[], None] | None = None):
        super().__init__(workers)
        self.start_method = start_method         # "fork", "spawn", "forkserver" (None: o do sistema)
        self.initializer = initializer           # roda uma vez em cada trabalhador quando ele nasce

    def _new_pool(self) -> Executor:
        """o pool já com todos os trabalhadores de pé. Com spawn eles nascem vazios e só nasceriam quando chega
        trabalho, um a um, pagando os imports e o núcleo no meio da primeira etapa pesada; aqui nascem todos juntos,
        cada um roda o `initializer` (os imports, o núcleo carregado) em paralelo, e a primeira etapa já roda quente"""
        import multiprocessing as mp
        ctx = mp.get_context(self.start_method) if self.start_method else None
        pool = ProcessPoolExecutor(max_workers=self.workers, mp_context=ctx, initializer=self.initializer)
        wait([pool.submit(_ready) for _ in range(self.workers)])
        return pool

    def _stop(self) -> None:
        # a conta que está rodando num processo não tem como ouvir o Parar: o processo é encerrado
        if self._pool is not None:
            for proc in list((getattr(self._pool, "_processes", None) or {}).values()):
                proc.terminate()
        super()._stop()


def _ready() -> None:
    """a tarefa vazia que faz cada trabalhador nascer"""


def make_executor(kind: str = "processos", workers: int | None = None, start_method: str | None = None,
                  initializer: Callable[[], None] | None = None) -> IExecutor:
    """o executor de um tipo de `KINDS`; `initializer` só vale para processos (as threads já dividem o que o
    processo carregou)"""
    if kind == "não":
        return SerialExecutor()
    if kind == "threads":
        return ThreadExecutor(workers)
    if kind == "processos":
        return ProcessExecutor(workers, start_method, initializer)
    raise ValueError(f"paralelismo desconhecido: {kind!r} (um de {', '.join(KINDS)})")


class Executors:
    """um executor de cada tipo, criado na primeira vez que alguém pede e guardado até `close`: as etapas de uma
    rodada pedem o tipo que querem e todas dividem os mesmos trabalhadores"""

    def __init__(self, workers: int | None = None, start_method: str | None = None,
                 initializer: Callable[[], None] | None = None):
        self.workers, self.start_method, self.initializer = workers, start_method, initializer
        self._made: dict[str, IExecutor] = {}

    def get(self, kind: str) -> IExecutor:
        if kind not in self._made:
            self._made[kind] = make_executor(kind, self.workers, self.start_method, self.initializer)
        return self._made[kind]

    def close(self) -> None:
        for ex in self._made.values():
            ex.close()
        self._made.clear()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
