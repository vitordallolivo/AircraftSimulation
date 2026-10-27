"""As três formas de rodar uma função em muitos itens (`aerosim.interfaces.executor.IExecutor`).

Em série, a conta roda na linha de quem chama. Em linhas de execução, todas dividem o GIL: só ganha a parte que
passa no núcleo (as chamadas por ctypes soltam o GIL). Em processos, cada trabalhador tem o seu Python e o seu
núcleo, então não há GIL a dividir, mas nascer custa (o spawn importa tudo de novo) e cada item vai e volta por
pickle. Por isso o executor de processos guarda os trabalhadores entre um `map` e o próximo: numa rodada de
várias etapas e várias gerações, eles nascem uma vez.

O Parar é combinado, não à força: a conta olha `cancelled()` (ou chama `check_cancel()`) entre um passo e outro, e
quem está rodando para sozinho, sem perder o processo. Só quem não para em `GRACE` segundos (uma chamada longa ao
núcleo, que não tem como olhar) é encerrado.
"""
from __future__ import annotations

import atexit
import os
import threading
from collections.abc import Callable, Sequence
from concurrent.futures import (FIRST_COMPLETED, BrokenExecutor, Executor, ProcessPoolExecutor, ThreadPoolExecutor,
                                wait)
from typing import Any

from aerosim.interfaces.executor import KINDS, IExecutor, Outcome

POLL = 0.2              # s: de quanto em quanto o `cancel` é olhado enquanto os trabalhadores contam
GRACE = 2.0             # s: quanto o Parar espera a conta parar sozinha antes de encerrar o processo


class Cancelled(Exception):
    """a conta viu o Parar e saiu no meio (`check_cancel`); o item volta como cancelado, não como erro"""


# quem olha o Parar: num processo trabalhador, o sinal que o pool passou ao nascer; no processo de quem chama (série e
# threads), o `cancel` do `map` em andamento
_FLAG = None
_LOCAL = threading.local()
_LOCAL_CHECKS: list[Callable[[], bool]] = []


def cancelled() -> bool:
    """o Parar foi pedido para a conta que está rodando aqui?"""
    if _FLAG is not None:
        return _FLAG.is_set()
    check = getattr(_LOCAL, "check", None) or (_LOCAL_CHECKS[-1] if _LOCAL_CHECKS else None)
    return bool(check is not None and check())


def check_cancel() -> None:
    """sai da conta (com `Cancelled`) se o Parar foi pedido: chamar entre um passo e outro de uma conta longa"""
    if cancelled():
        raise Cancelled("cancelado")


def _init_worker(flag, initializer) -> None:
    global _FLAG
    _FLAG = flag
    if initializer is not None:
        initializer()


def _outcome(f) -> Outcome:
    try:
        return Outcome(f.result())
    except Cancelled:
        return Outcome(cancelled=True)
    except Exception as e:  # noqa: BLE001 — um item que quebra para ali; os outros seguem
        return Outcome(error=e)


def default_workers() -> int:
    return max(1, os.cpu_count() or 1)


class SerialExecutor(IExecutor):
    kind = "não"

    def __init__(self, workers: int | None = None):
        self.workers = 1

    def map(self, fn, items, cancel=None, on_done=None) -> list[Outcome]:
        out = []
        prev, _LOCAL.check = getattr(_LOCAL, "check", None), cancel
        try:
            for j, it in enumerate(items):
                if cancel is not None and cancel():
                    r = Outcome(cancelled=True)
                else:
                    try:
                        r = Outcome(fn(it))
                    except Cancelled:
                        r = Outcome(cancelled=True)
                    except Exception as e:  # noqa: BLE001 — um item que quebra para ali; os outros seguem
                        r = Outcome(error=e)
                out.append(r)
                if not r.cancelled and on_done:
                    on_done(j, r)
        finally:
            _LOCAL.check = prev
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
        """o Parar à força: solta o pool sem esperar a conta que está rodando"""
        if self._pool is not None:
            self._pool.shutdown(wait=False, cancel_futures=True)
            self._pool = None

    def _signal(self, on: bool) -> None:
        """liga ou desliga o Parar combinado para quem está rodando"""

    def _soft_stop(self, pending: set) -> bool:
        """o Parar combinado: o que não começou é cancelado, quem está rodando vê o sinal e sai; True se todos
        saíram dentro de `GRACE` (o pool continua de pé)"""
        self._signal(True)
        try:
            for f in pending:
                f.cancel()
            _, left = wait(pending, timeout=GRACE)
            return not left
        finally:
            self._signal(False)

    def map(self, fn: Callable[[Any], Any], items: Sequence[Any], cancel=None, on_done=None) -> list[Outcome]:
        items = list(items)
        if len(items) < 2 or self.workers == 1:      # um item só não paga a ida e a volta
            return SerialExecutor().map(fn, items, cancel, on_done)
        self.start()
        out: list[Outcome | None] = [None] * len(items)
        futs = {self._pool.submit(fn, it): j for j, it in enumerate(items)}
        pending = set(futs)
        stopped = broken = False
        if cancel is not None:
            _LOCAL_CHECKS.append(cancel)             # as threads olham o mesmo `cancel`
        try:
            while pending:
                # espera pouco por vez: o Parar é visto em uma fração de segundo, não quando o próximo termina
                done, pending = wait(pending, timeout=POLL, return_when=FIRST_COMPLETED)
                for f in done:
                    j = futs[f]
                    out[j] = _outcome(f)
                    broken = broken or isinstance(out[j].error, BrokenExecutor)
                    if on_done and not out[j].cancelled:
                        on_done(j, out[j])
                if cancel is not None and cancel():
                    stopped = True
                    break
        finally:
            hard = broken or (stopped and not self._soft_stop(pending))
            if cancel is not None:
                _LOCAL_CHECKS.remove(cancel)
            if hard:
                self._stop()                         # quem não parou sozinho é encerrado
        for f in () if hard else pending:            # o que terminou enquanto o Parar esperava vale
            if f.done() and not f.cancelled() and out[futs[f]] is None:
                out[futs[f]] = _outcome(f)
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
                 initializer: Callable[[], None] | None = None, preload: Sequence[str] = ()):
        super().__init__(workers)
        self.start_method = start_method         # "fork", "spawn", "forkserver" (None: o do sistema)
        self.initializer = initializer           # roda uma vez em cada trabalhador quando ele nasce
        self.preload = tuple(preload)            # forkserver: módulos que o servidor importa uma vez
        self._flag = None

    def _new_pool(self) -> Executor:
        """o pool já com todos os trabalhadores de pé. Com spawn eles nascem vazios e só nasceriam quando chega
        trabalho, um a um, pagando os imports e o núcleo no meio da primeira etapa pesada; aqui nascem todos juntos,
        cada um roda o `initializer` (os imports, o núcleo carregado) em paralelo, e a primeira etapa já roda quente"""
        import multiprocessing as mp
        ctx = mp.get_context(self.start_method) if self.start_method else mp.get_context()
        if self.preload and ctx.get_start_method() == "forkserver":
            # o servidor nasce uma vez por sessão do Python e importa estes módulos; cada trabalhador depois é uma
            # cópia dele (fork), já com tudo carregado: um pool novo abre em centésimos de segundo
            ctx.set_forkserver_preload(list(self.preload))
        self._flag = ctx.Event()
        pool = ProcessPoolExecutor(max_workers=self.workers, mp_context=ctx, initializer=_init_worker,
                                   initargs=(self._flag, self.initializer))
        wait([pool.submit(_ready) for _ in range(self.workers)])
        return pool

    def _signal(self, on: bool) -> None:
        if self._flag is not None:
            (self._flag.set if on else self._flag.clear)()

    def _stop(self) -> None:
        # a conta que não parou sozinha (uma chamada longa ao núcleo não tem como olhar o sinal): o processo é encerrado
        if self._pool is not None:
            for proc in list((getattr(self._pool, "_processes", None) or {}).values()):
                proc.terminate()
        super()._stop()


def _ready() -> None:
    """a tarefa vazia que faz cada trabalhador nascer"""


def make_executor(kind: str = "processos", workers: int | None = None, start_method: str | None = None,
                  initializer: Callable[[], None] | None = None, preload: Sequence[str] = ()) -> IExecutor:
    """o executor de um tipo de `KINDS`; `initializer` só vale para processos (as threads já dividem o que o
    processo carregou)"""
    if kind == "não":
        return SerialExecutor()
    if kind == "threads":
        return ThreadExecutor(workers)
    if kind == "processos":
        return ProcessExecutor(workers, start_method, initializer, preload)
    raise ValueError(f"paralelismo desconhecido: {kind!r} (um de {', '.join(KINDS)})")


class Executors:
    """um executor de cada tipo, criado na primeira vez que alguém pede e guardado até `close`: as etapas de uma
    rodada pedem o tipo que querem e todas dividem os mesmos trabalhadores"""

    def __init__(self, workers: int | None = None, start_method: str | None = None,
                 initializer: Callable[[], None] | None = None, preload: Sequence[str] = ()):
        self.workers, self.start_method, self.initializer = workers, start_method, initializer
        self.preload = tuple(preload)
        self._made: dict[str, IExecutor] = {}

    def get(self, kind: str) -> IExecutor:
        if kind not in self._made:
            self._made[kind] = make_executor(kind, self.workers, self.start_method, self.initializer, self.preload)
        return self._made[kind]

    def close(self) -> None:
        for ex in self._made.values():
            ex.close()
        self._made.clear()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


_SESSION: dict[tuple, Executors] = {}
_SESSION_LOCK = threading.Lock()


def session(workers: int | None = None, start_method: str | None = None,
            initializer: Callable[[], None] | None = None, preload: Sequence[str] = ()) -> Executors:
    """os executores da sessão: os mesmos para todas as rodadas com estes parâmetros, até o Python fechar. A janela
    abre o pool assim que aparece (`warm_session`), e a primeira rodada já encontra os trabalhadores de pé"""
    key = (workers, start_method, initializer, tuple(preload))
    with _SESSION_LOCK:
        if key not in _SESSION:
            _SESSION[key] = Executors(workers, start_method, initializer, preload)
        return _SESSION[key]


def warm_session(*args, **kw) -> threading.Thread:
    """abre o pool de processos da sessão numa linha de fundo (quem chama não espera)"""
    ex = session(*args, **kw)
    t = threading.Thread(target=lambda: ex.get("processos").start(), daemon=True, name="pool da sessão")
    t.start()
    return t


def close_session() -> None:
    with _SESSION_LOCK:
        for ex in _SESSION.values():
            ex.close()
        _SESSION.clear()


atexit.register(close_session)
