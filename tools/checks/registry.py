"""Registro dos checks: cada check é uma função que devolve um `Result`, com nome e grupo.

Um check novo é só uma função com `@check("grupo", "nome")` num módulo importado por `run.py`. O grupo é a área
(fundação, aerodrive, regressão, testes) e escolhe o que roda com `--grupos`.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass, field

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@dataclass
class Result:
    ok: bool
    resumo: str = ""                       # uma linha
    detalhes: list[str] = field(default_factory=list)
    pulado: bool = False                   # não rodou (falta ferramenta, sem base...)


@dataclass
class Check:
    grupo: str
    nome: str
    fn: object
    lento: bool = False                    # só roda com --tudo


CHECKS: list[Check] = []


def check(grupo: str, nome: str, lento: bool = False):
    def deco(fn):
        CHECKS.append(Check(grupo, nome, fn, lento))
        return fn
    return deco


def zig_cmd() -> list[str]:
    """o mesmo zig que o backend usa (pacote ziglang do pip, ou o do sistema)"""
    try:
        import ziglang  # noqa: F401
        return [sys.executable, "-m", "ziglang"]
    except ImportError:
        return ["zig"]


def sh(cmd: list[str], cwd: str, timeout: float = 1800, env: dict | None = None) -> tuple[int, str, float]:
    """roda um comando; (código de saída, saída junta, segundos)"""
    t = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, **(env or {})})
        return p.returncode, (p.stdout or "") + (p.stderr or ""), time.time() - t
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out + f"\n(tempo esgotado: {timeout:.0f} s)", time.time() - t
    except FileNotFoundError as e:
        return 127, str(e), time.time() - t


def tail(text: str, n: int = 15) -> list[str]:
    return [ln for ln in text.strip().splitlines()[-n:]]
