"""Regressão bit a bit: retrata os aviões de exemplo no código atual e numa referência (um commit, padrão a `main`)
e compara número a número.

A referência roda numa cópia separada do repositório (`git worktree`) com a biblioteca do núcleo compilada a partir
dela. Os retratos ficam em cache fora do repositório (`~/.cache/aerosim-checks`), um por commit; o do código atual só
entra no cache se não houver mudança local.

Uma diferença não é sempre um erro: uma mudança de física pedida muda os números. O check diz **o que** mudou
(arquivo, parte, maior diferença); quem decide é quem lê.
"""
from __future__ import annotations

import os
import pickle
import subprocess
import sys

import numpy as np

from registry import ROOT, Result, check, sh, tail

CACHE = os.path.join(os.path.expanduser("~"), ".cache", "aerosim-checks")
HERE = os.path.dirname(os.path.abspath(__file__))
OPTS = {"ref": "origin/main", "rapido": False}     # trocados pelo run.py (--ref, --rapido)


def _git(*args) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


def _tree_for(sha: str) -> str:
    path = os.path.join(CACHE, "trees", sha[:12])
    if not os.path.isdir(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.run(["git", "worktree", "add", "--detach", path, sha], cwd=ROOT, check=True,
                       capture_output=True, text=True)
    return path


def _snapshot(tree: str, out: str) -> tuple[bool, str]:
    cmd = [sys.executable, os.path.join(HERE, "snapshot.py"), "--raiz", tree, "--saida", out]
    if OPTS["rapido"]:
        cmd.append("--rapido")
    code, text, _ = sh(cmd, cwd=tree, timeout=3600)
    return code == 0, text


def _cached(sha: str, tree: str) -> tuple[dict | None, str]:
    tag = "rapido" if OPTS["rapido"] else "completo"
    out = os.path.join(CACHE, f"{sha[:12]}_{tag}.pkl")
    if not os.path.exists(out):
        ok, text = _snapshot(tree, out)
        if not ok:
            return None, text
    with open(out, "rb") as fh:
        return pickle.load(fh), ""


def _cmp(a, b, path: str, diffs: list[str]) -> None:
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a or k not in b:
                diffs.append(f"{path}/{k}: só {'na referência' if k in a else 'no atual'}")
            else:
                _cmp(a[k], b[k], f"{path}/{k}", diffs)
    elif isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        if len(a) != len(b):
            diffs.append(f"{path}: tamanho {len(a)} → {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            _cmp(x, y, f"{path}[{i}]", diffs)
    elif isinstance(a, np.ndarray) or isinstance(b, np.ndarray):
        x, y = np.asarray(a), np.asarray(b)
        if x.shape != y.shape:
            diffs.append(f"{path}: forma {x.shape} → {y.shape}")
        elif not np.array_equal(x, y, equal_nan=True):
            d = np.nanmax(np.abs(x.astype(float) - y.astype(float))) if x.dtype.kind in "fiub" else float("nan")
            diffs.append(f"{path}: maior diferença {d:.3g}")
    elif isinstance(a, float) and isinstance(b, float):
        if not (a == b or (a != a and b != b)):
            diffs.append(f"{path}: {a!r} → {b!r}")
    elif a != b:
        diffs.append(f"{path}: {str(a)[:60]!r} → {str(b)[:60]!r}")


@check("regressão", "exemplos bit a bit contra a referência", lento=False)
def golden() -> Result:
    try:
        ref_sha = _git("rev-parse", OPTS["ref"])
        head_sha = _git("rev-parse", "HEAD")
        dirty = bool(_git("status", "--porcelain", "--untracked-files=no"))
    except subprocess.CalledProcessError as e:
        return Result(False, f"git: {e.stderr.strip()}", pulado=True)
    ref, err = _cached(ref_sha, _tree_for(ref_sha))
    if ref is None:
        return Result(False, f"o retrato da referência {OPTS['ref']} falhou", tail(err, 20))
    if dirty:
        out = os.path.join(CACHE, "atual.pkl")
        ok, text = _snapshot(ROOT, out)
        if not ok:
            return Result(False, "o retrato do código atual falhou", tail(text, 20))
        with open(out, "rb") as fh:
            cur = pickle.load(fh)
    else:
        cur, err = _cached(head_sha, ROOT)
        if cur is None:
            return Result(False, "o retrato do código atual falhou", tail(err, 20))
    same, changed, details = [], [], []
    for f in sorted(set(ref) | set(cur)):
        if f not in ref or f not in cur:
            details.append(f"{f}: só {'na referência' if f in ref else 'no atual'} (não comparado)")
            continue
        diffs: list[str] = []
        _cmp(ref[f], cur[f], "", diffs)
        if diffs:
            changed.append(f)
            details.append(f"{f}: {len(diffs)} diferença(s)")
            details += [f"    {d}" for d in diffs[:6]] + ([f"    … +{len(diffs) - 6}"] if len(diffs) > 6 else [])
        else:
            same.append(f)
    tag = f"{OPTS['ref']} ({ref_sha[:8]}) → {'atual com mudanças locais' if dirty else head_sha[:8]}"
    if changed:
        return Result(False, f"{len(changed)} de {len(same) + len(changed)} exemplos mudaram; {tag}", details)
    return Result(True, f"{len(same)} exemplos idênticos; {tag}", details)
