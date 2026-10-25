"""O executor genérico (aerosim/parallel): os três tipos dão o mesmo resultado, na ordem, com os erros no item que
quebrou; o Parar é visto no meio; os processos ficam vivos entre um `map` e o próximo."""
import os
import threading
import time

import pytest

from aerosim.interfaces.executor import KINDS, IExecutor
from aerosim.parallel import Executors, make_executor


def _square(x):
    if x == 3:
        raise ValueError("três não")
    return x * x


def _pid(_):
    return os.getpid()


def _slow(x):
    time.sleep(0.3 if x else 0.0)
    return x


@pytest.mark.parametrize("kind", KINDS)
def test_same_result_in_order_with_errors_in_place(kind):
    with make_executor(kind, workers=3, start_method="fork" if kind == "processos" else None) as ex:
        assert isinstance(ex, IExecutor) and ex.kind == kind
        seen = []
        res = ex.map(_square, range(8), on_done=lambda j, r: seen.append(j))
    assert [r.value for r in res if r.ok] == [0, 1, 4, 16, 25, 36, 49]
    assert isinstance(res[3].error, ValueError) and not res[3].ok
    assert sorted(seen) == list(range(8))


def test_processes_live_through_the_whole_run():
    ex = make_executor("processos", workers=2, start_method="fork")
    first = {r.value for r in ex.map(_pid, range(6))}
    second = {r.value for r in ex.map(_pid, range(6))}
    assert os.getpid() not in first and first & second           # os mesmos trabalhadores no segundo lote
    ex.close()
    third = {r.value for r in ex.map(_pid, range(6))}             # depois de fechar, nascem de novo
    assert not third & first
    ex.close()


@pytest.mark.filterwarnings("ignore:This process.*is multi-threaded:DeprecationWarning")   # o Timer é uma linha
@pytest.mark.parametrize("kind", ("threads", "processos"))
def test_cancel_stops_in_a_fraction_of_a_second(kind):
    stop = threading.Event()
    ex = make_executor(kind, workers=2, start_method="fork" if kind == "processos" else None)
    threading.Timer(0.1, stop.set).start()
    t0 = time.perf_counter()
    res = ex.map(_slow, [1] * 12, cancel=stop.is_set)
    assert time.perf_counter() - t0 < 1.5
    assert any(r.cancelled for r in res)
    assert [r.value for r in ex.map(_slow, [0, 0, 0])] == [0, 0, 0]   # o executor volta a servir depois do Parar
    ex.close()


def test_serial_cancel_and_executors_share_one_of_each_kind():
    res = make_executor("não").map(_square, range(4), cancel=lambda: True)
    assert all(r.cancelled for r in res)
    with Executors(workers=2) as ex:
        assert ex.get("threads") is ex.get("threads") and ex.get("não").workers == 1
    with pytest.raises(ValueError):
        make_executor("gpu")


_WARM = []


def _mark():
    _WARM.append(os.getpid())


def _was_warmed(_):
    return list(_WARM)


def test_process_pool_starts_every_worker_warm():
    """todos os trabalhadores nascem juntos e rodam o `initializer` antes do primeiro item"""
    with make_executor("processos", workers=3, start_method="fork", initializer=_mark) as ex:
        res = ex.map(_was_warmed, range(9))
        assert all(r.ok and r.value for r in res)                  # cada um já passou pelo initializer
        assert len(ex._pool._processes) == 3
