"""O processo em etapas: todos os candidatos passam por uma etapa, e a próxima só começa quando o último chega.

Esperar todo mundo (a barreira) é o que deixa paralelizar fácil: dentro de uma etapa os candidatos não dependem
uns dos outros, então cada um vai para um processo (ou uma linha de execução) e a etapa termina quando todos
voltam. Depois da barreira a etapa escolhe quem segue (`select`), já vendo todos, e a próxima recebe só esses.
Uma etapa pode também tratar o lote inteiro de uma vez (a nota, que o núcleo calcula para todos numa chamada).

    p = Pipeline([Configurations(...), SurfaceSizing(...), Takeoff6dof(...), Score(...)])
    itens = p.run(workers=4, progress=lambda f, txt: print(f"{f:4.0%} {txt}"))
"""
from __future__ import annotations

import os
from collections.abc import Callable
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, ThreadPoolExecutor, wait

from aerosim.interfaces.optim import IStage, StageItem


def _fail(item: StageItem, stage: str, err: Exception) -> StageItem:
    # ValueError é o "não passou" de uma etapa (o motivo já está no texto); outro erro é falha de conta e leva o tipo
    kind = "" if type(err) is ValueError else f"{type(err).__name__}: "
    item.alive, item.why = False, f"{stage}: {kind}{err}"
    return item


class Pipeline:
    def __init__(self, stages: list[IStage], start_method: str | None = None):
        self.stages = list(stages)
        self.start_method = start_method                  # processos: "fork", "spawn"... (None = o do sistema)
        self.log: list[tuple[str, int, int]] = []         # por etapa: nome, quantos entraram, quantos seguiram

    def run(self, items: list[StageItem] | None = None, workers: int | None = None,
            progress: Callable[[float, str], None] | None = None,
            cancel: Callable[[], bool] | None = None,
            on_item: Callable[[str, StageItem], None] | None = None) -> list[StageItem]:
        """roda as etapas em ordem; devolve todos os candidatos (os que pararam têm `alive = False` e o motivo).
        `on_item(etapa, candidato)` a cada candidato que termina uma etapa (quem mostra o andamento ao vivo)"""
        items = list(items or [])
        n_st = len(self.stages)
        for k, st in enumerate(self.stages):
            if cancel is not None and cancel():
                break
            alive = [i for i in items if i.alive]
            done = 0

            def tick(it: StageItem, k=k, st=st, alive=alive):
                nonlocal done
                done += 1
                it.stage = st.name
                if progress:
                    progress((k + done / max(len(alive), 1)) / n_st, f"{st.name}: {it.name} ({done}/{len(alive)})")
                if on_item:
                    on_item(st.name, it)

            if st.batch:
                out = st.run(alive)
                for it in out:
                    tick(it)
            else:
                out = self._map(st, alive, workers, tick, cancel)
            pos = {id(a): j for j, a in enumerate(alive)}
            new = {pos[id(a)]: o for a, o in zip(alive, out)}
            items = [new.get(pos.get(id(i), -1), i) for i in items]
            kept = st.select([i for i in items if i.alive])
            keep = {id(i) for i in kept}
            for i in items:
                if i.alive and id(i) not in keep:
                    i.alive, i.why = False, i.why or f"{st.name}: não foi escolhido"
            self.log.append((st.name, len(alive), len(kept)))
        return items

    def _map(self, st: IStage, alive: list[StageItem], workers, tick, cancel) -> list[StageItem]:
        """`st.one` em cada candidato; a ordem da lista é mantida (o resultado não depende do paralelismo)"""
        n = workers or max(1, min(len(alive), os.cpu_count() or 2))
        out: list[StageItem | None] = [None] * len(alive)
        if st.parallel == "não" or n == 1 or len(alive) < 2:
            for j, it in enumerate(alive):
                if cancel is not None and cancel():
                    out[j] = _fail(it, st.name, RuntimeError("cancelado"))
                    continue
                try:
                    out[j] = st.one(it)
                except Exception as e:  # noqa: BLE001 — um candidato que quebra para ali; os outros seguem
                    out[j] = _fail(it, st.name, e)
                tick(out[j])
            return out
        if st.parallel == "processos":
            import multiprocessing as mp
            ctx = mp.get_context(self.start_method) if self.start_method else None
            pool = ProcessPoolExecutor(max_workers=n, mp_context=ctx)
        else:
            pool = ThreadPoolExecutor(max_workers=n)
        stopped = False
        futs = {pool.submit(st.one, it): j for j, it in enumerate(alive)}
        pending = set(futs)
        try:
            while pending:
                # espera pouco por vez: o Parar é visto em uma fração de segundo, não quando o próximo termina
                done, pending = wait(pending, timeout=0.2, return_when=FIRST_COMPLETED)
                for f in done:
                    j = futs[f]
                    try:
                        out[j] = f.result()
                    except Exception as e:  # noqa: BLE001
                        out[j] = _fail(alive[j], st.name, e)
                    tick(out[j])
                if cancel is not None and cancel():
                    stopped = True
                    break
        finally:
            if stopped:
                # a conta que está rodando num processo não tem como ouvir o Parar: o processo é encerrado
                for proc in list((getattr(pool, "_processes", None) or {}).values()):
                    proc.terminate()
            pool.shutdown(wait=not stopped, cancel_futures=True)
        return [o if o is not None else _fail(a, st.name, RuntimeError("cancelado")) for o, a in zip(out, alive)]
