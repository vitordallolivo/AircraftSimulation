"""Documentação: o mapa do código (docs/MAP.md) tem de estar em dia com o código, e as tabelas do Quadro do
docs/TRACKING.md têm de estar legíveis para a página do tracking. As equações dos .md ficam nas duas formas em que o
GitHub não mexe no TeX: ```math para bloco e $`...`$ no meio do texto."""
from __future__ import annotations

import os
import re
import subprocess
import sys

from registry import ROOT, Result, check, sh


@check("fundação", "mapa do código em dia (docs/MAP.md)")
def codemap_up_to_date() -> Result:
    code, out, _ = sh([sys.executable, os.path.join(ROOT, "tools", "codemap.py"), "--check"], cwd=ROOT, timeout=120)
    if code != 0:
        return Result(False, "desatualizado: rode python tools/codemap.py", out.strip().splitlines()[-3:])
    return Result(True, "em dia")


@check("fundação", "tabelas do Quadro do TRACKING.md legíveis")
def tracking_up_to_date() -> Result:
    code, out, _ = sh([sys.executable, os.path.join(ROOT, "tools", "tracking.py"), "--check"], cwd=ROOT, timeout=60)
    if code != 0:
        return Result(False, "linha com colunas a mais ou a menos", out.strip().splitlines()[-2:])
    return Result(True, "em dia")


@check("fundação", "equações dos .md na forma que o GitHub desenha")
def equations_github_form() -> Result:
    """$$...$$ e $...$ passam antes pelo Markdown do GitHub, que come as barras invertidas e os _ viram itálico"""
    listed = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True, text=True).stdout.split()
    wrong = []
    for path in listed:
        if path.startswith("data/"):
            continue
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            text = f.read()
        text = re.sub(r"^\s*(```|~~~).*?^\s*\1", "", text, flags=re.S | re.M)   # blocos de código e ```math
        text = re.sub(r"\$`.+?`\$", "", text)                                    # $`...`$
        text = re.sub(r"`[^`\n]+`", "", text)                                      # código no texto
        for line in text.split("\n"):
            if "$$" in line or re.search(r"(?<![\\$])\$[^$\s][^$]*?\$(?!\$)", line):
                wrong.append(f"{path}: {line.strip()[:80]}")
    if wrong:
        return Result(False, f"{len(wrong)} linhas com $$ ou $...$: use ```math ou $`...`$", wrong[:5])
    return Result(True, "em dia")
