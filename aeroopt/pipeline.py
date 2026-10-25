"""O processo em etapas: todos os candidatos passam por uma etapa, e a próxima só começa quando o último chega.

Esperar todo mundo (a barreira) é o que deixa paralelizar fácil: dentro de uma etapa os candidatos não dependem
uns dos outros, então cada um vai para um processo (ou uma linha de execução) e a etapa termina quando todos
voltam. Depois da barreira a etapa escolhe quem segue (`select`), já vendo todos, e a próxima recebe só esses.
Uma etapa pode também tratar o lote inteiro de uma vez (a nota, que o núcleo calcula para todos numa chamada).

    p = Pipeline([Configurations(...), SurfaceSizing(...), Takeoff6dof(...), Score(...)])
    itens = p.run(workers=4, progress=lambda f, txt: print(f"{f:4.0%} {txt}"))

Quem roda os candidatos é um executor genérico (`aerosim.parallel`): cada etapa pede o tipo que quer (`parallel`:
"processos", "threads" ou "não") e as etapas dividem os mesmos trabalhadores. Quem roda várias vezes (as gerações)
passa um `Executors` próprio, e os processos nascem uma vez para a rodada inteira.
"""
from __future__ import annotations

import time
from collections.abc import Callable

from aerosim.interfaces.executor import KINDS, IExecutor, Outcome
from aerosim.interfaces.optim import IStage, StageItem
from aerosim.parallel import Executors


def _fail(item: StageItem, stage: str, err: Exception) -> StageItem:
    # ValueError é o "não passou" de uma etapa (o motivo já está no texto); outro erro é falha de conta e leva o tipo
    kind = "" if type(err) is ValueError else f"{type(err).__name__}: "
    item.alive, item.why = False, f"{stage}: {kind}{err}"
    return item


class Pipeline:
    def __init__(self, stages: list[IStage], start_method: str | None = None, executors: Executors | None = None,
                 initializer=None):
        self.stages = list(stages)
        self.start_method = start_method                  # processos: "fork", "spawn"... (None = o do sistema)
        self.initializer = initializer                    # o que cada processo carrega ao nascer (`stages.warm`)
        self.executors = executors                        # None: um conjunto só desta rodada, fechado no fim
        self.log: list[tuple[str, int, int]] = []         # por etapa: nome, quantos entraram, quantos seguiram
        self.times: list[tuple[str, float]] = []          # por etapa: nome e o tempo de parede dela (s)

    def run(self, items: list[StageItem] | None = None, workers: int | None = None,
            progress: Callable[[float, str], None] | None = None,
            cancel: Callable[[], bool] | None = None,
            on_item: Callable[[str, StageItem], None] | None = None) -> list[StageItem]:
        """roda as etapas em ordem; devolve todos os candidatos (os que pararam têm `alive = False` e o motivo).
        `on_item(etapa, candidato)` a cada candidato que termina uma etapa (quem mostra o andamento ao vivo)"""
        if self.executors is not None:
            return self._run(self.executors, items, workers, progress, cancel, on_item)
        with Executors(workers, self.start_method, self.initializer) as ex:
            return self._run(ex, items, workers, progress, cancel, on_item)

    def _run(self, ex: Executors, items, workers, progress, cancel, on_item) -> list[StageItem]:
        items = list(items or [])
        n_st = len(self.stages)
        for k, st in enumerate(self.stages):
            if cancel is not None and cancel():
                break
            alive = [i for i in items if i.alive]
            done = 0
            t0 = time.perf_counter()

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
                kind = "não" if workers == 1 else (st.parallel if st.parallel in KINDS else "processos")
                out = self._map(st, ex.get(kind), alive, tick, cancel)
            pos = {id(a): j for j, a in enumerate(alive)}
            new = {pos[id(a)]: o for a, o in zip(alive, out)}
            items = [new.get(pos.get(id(i), -1), i) for i in items]
            kept = st.select([i for i in items if i.alive])
            keep = {id(i) for i in kept}
            for i in items:
                if i.alive and id(i) not in keep:
                    i.alive, i.why = False, i.why or f"{st.name}: não foi escolhido"
            self.log.append((st.name, len(alive), len(kept)))
            self.times.append((st.name, time.perf_counter() - t0))
        return items

    @staticmethod
    def _map(st: IStage, runner: IExecutor, alive: list[StageItem], tick, cancel) -> list[StageItem]:
        """`st.one` em cada candidato; a ordem da lista é mantida (o resultado não depende do paralelismo)"""
        got: dict[int, StageItem] = {}

        def item(j: int, r: Outcome) -> StageItem:
            if r.ok:
                return r.value
            return _fail(alive[j], st.name, r.error if r.error is not None else RuntimeError("cancelado"))

        def done(j: int, r: Outcome):
            got[j] = item(j, r)
            tick(got[j])
        res = runner.map(st.one, alive, cancel, done)
        return [got[j] if j in got else item(j, r) for j, r in enumerate(res)]
