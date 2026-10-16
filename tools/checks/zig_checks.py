"""Fundação e AeroDrive: os testes do núcleo Zig e a compilação + testes do AeroDrive (que importa o núcleo)."""
from __future__ import annotations

import os
import re

from registry import ROOT, Result, check, sh, tail, zig_cmd


def _zig_test(folder: str, args: list[str]) -> Result:
    code, out, dt = sh(zig_cmd() + args, cwd=os.path.join(ROOT, folder))
    m = re.findall(r"(\d+)/(\d+) tests passed", out)
    passed = f"{m[-1][0]}/{m[-1][1]} testes" if m else ""
    if code == 127:
        return Result(False, "zig não encontrado (pip install ziglang)", tail(out), pulado=True)
    if code != 0:
        return Result(False, f"falhou em {dt:.0f} s", tail(out, 25))
    return Result(True, f"{passed} em {dt:.0f} s".strip())


@check("fundação", "núcleo Zig: zig build test")
def core_tests() -> Result:
    return _zig_test("core", ["build", "test", "--summary", "all"])


@check("aerodrive", "AeroDrive: compila (zig build)")
def aerodrive_build() -> Result:
    return _zig_test("aerodrive", ["build"])


@check("aerodrive", "AeroDrive: zig build test")
def aerodrive_tests() -> Result:
    return _zig_test("aerodrive", ["build", "test", "--summary", "all"])
