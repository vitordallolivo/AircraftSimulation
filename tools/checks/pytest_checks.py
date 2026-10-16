"""Os testes Python por área: uma pasta de `tests/` por check, para saber qual área quebrou e quanto cada uma demora.

As áreas são as pastas de `tests/` que existem; uma pasta nova vira um check sozinha. A GUI roda com
QT_QPA_PLATFORM=offscreen.
"""
from __future__ import annotations

import os
import re
import sys

from registry import ROOT, Result, check, sh, tail

TESTS = os.path.join(ROOT, "tests")
SLOW = {"gui", "design", "manager"}           # as que demoram mais: só com --tudo


def _run(target: str) -> Result:
    code, out, dt = sh([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", target], cwd=ROOT,
                       timeout=3600, env={"QT_QPA_PLATFORM": "offscreen"})
    last = [ln for ln in out.strip().splitlines() if re.search(r"\d+ (passed|failed|error)", ln)]
    summary = last[-1].strip("= ") if last else "sem resumo do pytest"
    if code == 5:                              # nenhum teste coletado
        return Result(True, "sem testes", pulado=True)
    if code != 0:
        fails = [ln for ln in out.splitlines() if ln.startswith(("FAILED", "ERROR"))]
        return Result(False, f"{summary} ({dt:.0f} s)", fails[:20] or tail(out, 20))
    return Result(True, f"{summary} ({dt:.0f} s)")


def _register():
    for name in sorted(os.listdir(TESTS)):
        p = os.path.join(TESTS, name)
        if not os.path.isdir(p) or name.startswith(("_", ".")) or name in ("helpers", "data"):
            continue
        check("testes", f"tests/{name}", lento=name in SLOW)(lambda p=p: _run(os.path.relpath(p, ROOT)))
    top = [f for f in os.listdir(TESTS) if f.startswith("test_") and f.endswith(".py")]
    for f in sorted(top):
        check("testes", f"tests/{f}")(lambda f=f: _run(os.path.join("tests", f)))


_register()
