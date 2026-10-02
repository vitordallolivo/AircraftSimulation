"""Ponte Python -> simulador em C.

    escreve_cfg(av, perc, cfg)                  configuracao (aeronave + percurso)
    roda("missao", cfg, prefixo, sobre, carrega=..., salva=...)
    decolagem(cfg, sobre) / polar(cfg, prefixo) / desempenho(cfg, prefixo)
    junta(a, b)                                 concatena dois trechos de trajetoria

Checkpoint: rode com salva="x.ckpt" e uma parada (para_seg, para_t ou
para_autop nas sobrescritas); depois rode de novo com carrega="x.ckpt" e
uma configuracao nova para as etapas seguintes.
"""
import os
import subprocess
import numpy as np

AQUI = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(AQUI, "..", "missao6gdl")


def compila():
    subprocess.run(["make", "-s", "-C", os.path.join(AQUI, "..")], check=True)


def _fmt(v):
    if isinstance(v, (tuple, list)):
        return " ".join(_fmt(x) for x in v)
    if isinstance(v, (bool, int)) and not isinstance(v, float):
        return str(int(v))
    return repr(float(v))


def escreve_cfg(av, perc, caminho):
    """av: aeronave.padrao(); perc: percurso.monta(...) ou percurso.circuito()"""
    with open(caminho, "w") as f:
        f.write("# gerado por simulador.py -- angulos em graus\n")
        for k, v in av["escalares"].items():
            f.write(f"{k} {_fmt(v)}\n")
        for s in av["superficies"]:
            f.write("superficie " + " ".join(f"{k}={v}" for k, v in s.items()) + "\n")
        for c in av["contatos"]:
            f.write("contato " + " ".join(f"{k}={v}" for k, v in c.items()) + "\n")
        for J, CT, CP in av["helice"]:
            f.write(f"helice J={J} CT={CT} CP={CP}\n")
        for s in perc["segmentos"]:
            f.write("segmento " + " ".join(f"{k}={v}" for k, v in s.items()) + "\n")
        for e in perc["eventos"]:
            f.write("evento " + " ".join(f"{k}={v}" for k, v in e.items()) + "\n")


def _sobre(sobre):
    out = []
    for k, v in (sobre or {}).items():
        out.append(f"{k}=" + (",".join(str(x) for x in v) if isinstance(v, (list, tuple)) else str(v)))
    return out


def _kv(texto):
    d = {}
    for linha in texto.splitlines():
        if "=" in linha:
            k, v = linha.split("=", 1)
            d[k.strip()] = float(v)
    return d


def tabela(caminho):
    with open(caminho) as f:
        cab = f.readline().split()
    try:
        d = np.loadtxt(caminho, skiprows=1, ndmin=2)
    except ValueError:
        d = np.zeros((0, len(cab)))
    if d.size == 0:
        d = np.zeros((0, len(cab)))
    return {k: d[:, i] for i, k in enumerate(cab)}


def roda(modo, cfg, prefixo, sobre=None, carrega=None, salva=None):
    cmd = [BIN, modo, cfg, prefixo]
    if carrega:
        cmd += ["--carrega", carrega]
    if salva:
        cmd += ["--salva", salva]
    r = subprocess.run(cmd + _sobre(sobre), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"simulador falhou ({' '.join(cmd)}):\n{r.stderr}")
    if modo == "decolagem":
        return _kv(r.stdout)
    if modo == "polar":
        return tabela(prefixo + "_polar.dat"), tabela(prefixo + "_polarb.dat"), _kv(r.stdout)
    if modo == "desempenho":
        return tabela(prefixo + "_desempenho.dat"), _kv(r.stdout)
    return dict(traj=tabela(prefixo + "_traj.dat"), solo=tabela(prefixo + "_solo.dat"),
                pacote=tabela(prefixo + "_pacote.dat"), eventos=_kv(open(prefixo + "_eventos.txt").read()))


def decolagem(cfg, sobre=None):
    return roda("decolagem", cfg, "-", sobre)


def junta(a, b):
    """concatena trajetorias (b comeca onde a parou)"""
    out = {}
    for k in ("traj", "solo", "pacote"):
        A, B = a[k], b[k]
        if len(A.get("t", [])) and len(B.get("t", [])):
            corte = A["t"] < B["t"][0] - 1e-9
            out[k] = {c: np.concatenate([A[c][corte], B[c]]) for c in A if c in B}
        else:
            out[k] = A if len(A.get("t", [])) else B
    ev = dict(a["eventos"])
    for k, v in b["eventos"].items():          # o trecho novo traz os eventos acumulados
        ev[k] = v
    out["eventos"] = ev
    return out
