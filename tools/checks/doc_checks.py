"""Documentação: o mapa do código (docs/MAP.md) tem de estar em dia com o código."""
from __future__ import annotations

import os
import sys

from registry import ROOT, Result, check, sh


@check("fundação", "mapa do código em dia (docs/MAP.md)")
def codemap_up_to_date() -> Result:
    code, out, _ = sh([sys.executable, os.path.join(ROOT, "tools", "codemap.py"), "--check"], cwd=ROOT, timeout=120)
    if code != 0:
        return Result(False, "desatualizado: rode python tools/codemap.py", out.strip().splitlines()[-3:])
    return Result(True, "em dia")
