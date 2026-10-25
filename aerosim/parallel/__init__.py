"""Paralelismo genérico: as formas de rodar uma função em muitos itens (`IExecutor`) e um conjunto delas que dura
uma rodada inteira. Ver o README desta pasta."""
from aerosim.interfaces.executor import KINDS, IExecutor, Outcome

from .executors import (Executors, ProcessExecutor, SerialExecutor, ThreadExecutor, default_workers,
                        make_executor)

__all__ = ["KINDS", "IExecutor", "Outcome", "Executors", "ProcessExecutor", "SerialExecutor", "ThreadExecutor",
           "default_workers", "make_executor"]
