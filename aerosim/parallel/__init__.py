"""Paralelismo genérico: as formas de rodar uma função em muitos itens (`IExecutor`) e um conjunto delas que dura
uma rodada inteira. Ver o README desta pasta."""
from aerosim.interfaces.executor import KINDS, IExecutor, Outcome

from .executors import (Cancelled, Executors, ProcessExecutor, SerialExecutor, ThreadExecutor, cancelled,
                        check_cancel, close_session, default_workers, make_executor, session, warm_session)

__all__ = ["KINDS", "IExecutor", "Outcome", "Cancelled", "Executors", "ProcessExecutor", "SerialExecutor",
           "ThreadExecutor", "cancelled", "check_cancel", "close_session", "default_workers", "make_executor",
           "session", "warm_session"]
