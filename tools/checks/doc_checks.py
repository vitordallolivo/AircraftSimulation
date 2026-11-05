"""Documentação: o mapa do código (docs/MAP.md) tem de estar em dia com o código, e o Quadro do docs/TRACKING.md com o
docs/tracking.json."""
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


@check("fundação", "Quadro do TRACKING.md igual ao tracking.json")
def tracking_up_to_date() -> Result:
    code, out, _ = sh([sys.executable, os.path.join(ROOT, "tools", "tracking.py"), "--check"], cwd=ROOT, timeout=60)
    if code != 0:
        return Result(False, "desatualizado: rode python tools/tracking.py", out.strip().splitlines()[-2:])
    return Result(True, "em dia")
