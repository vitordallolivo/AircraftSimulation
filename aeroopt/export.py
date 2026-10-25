"""O registro de uma rodada em CSV: cada avião avaliado, em ordem, com as variáveis que mudaram nele.

Dois arquivos por rodada, numa pasta só:

    avaliacoes.csv      um ponto de projeto por linha, na ordem de cada configuração: nº da configuração, nº da
                        avaliação dentro dela, a categoria e as escolhas discretas, cada variável contínua, MTOW na
                        pista, PV, envergadura, bateria, se fecha e por que não
    configuracoes.csv   uma configuração por linha: os valores do melhor ponto dela, até que etapa chegou, MTOW
                        na pista e no 6GDL, as entradas da nota, cada fator, cada condição de voo válido e a nota

Separador `;` e vírgula decimal, que o Excel e o LibreOffice em português abrem direto. No pandas:
`pd.read_csv(arq, sep=";", decimal=",")`.

    pasta = write(res.rows, "rodadas_aeroopt/micro")
"""
from __future__ import annotations

import csv
import math
import os
import time

SEP = ";"


def _num(v) -> str:
    if isinstance(v, bool):
        return "sim" if v else "não"
    if isinstance(v, (int, float)):
        if isinstance(v, float) and not math.isfinite(v):
            return ""
        return f"{v:.6g}".replace(".", ",")
    return str(v)


def _keys(rows: list[dict], field: str) -> list[str]:
    return list(dict.fromkeys(k for r in rows for k in r.get(field, {})))


def evaluations(rows: list[dict]) -> tuple[list[str], list[list]]:
    """as linhas de avaliacoes.csv (cabeçalho, linhas)"""
    fixed = _keys(rows, "values")                     # as discretas (categoria, hélice...) e as contínuas
    cont = list(dict.fromkeys(k for r in rows for h in r.get("history", []) for k in h["values"]))
    disc = [k for k in fixed if k not in cont]
    head = ["configuração nº", "avaliação nº", "configuração"] + disc + cont + \
        ["MTOW pista (kg)", "PV (kg)", "envergadura (m)", "bateria (kg)", "fecha", "motivo"]
    out = []
    for r in sorted(rows, key=lambda r: r.get("index", 0)):
        for k, h in enumerate(r.get("history", []), 1):
            out.append([r.get("index", 0), k, r["name"]] + [r["values"].get(c, "") for c in disc] +
                       [h["values"].get(c, "") for c in cont] +
                       [h["mtow"], h["pv"], h["b"], h["m_bat"], h["ok"], h["why"]])
    return head, out


def configurations(rows: list[dict]) -> tuple[list[str], list[list]]:
    """as linhas de configuracoes.csv (cabeçalho, linhas)"""
    vals, ins, terms = _keys(rows, "values"), _keys(rows, "inputs"), _keys(rows, "termos")
    checks = list(dict.fromkeys(t for r in rows for t, _ok, _x in r.get("validade", [])))
    head = ["configuração nº", "configuração"] + vals + ["última etapa", "chegou ao fim", "motivo", "MTOW pista (kg)",
                                                          "MTOW 6GDL (kg)", "PV (kg)"] + \
        [f"entrada: {k}" for k in ins] + [f"fator: {k}" for k in terms] + [f"cumpre: {t}" for t in checks] + \
        ["voo válido", "nota"]
    out = []
    for r in sorted(rows, key=lambda r: r.get("index", 0)):
        ok = {t: o for t, o, _x in r.get("validade", [])}
        out.append([r.get("index", 0), r["name"]] + [r["values"].get(k, "") for k in vals] +
                   [r.get("stage", ""), r["alive"], r["why"], r["mtow"], r["mtow6"], r["pv"]] +
                   [r.get("inputs", {}).get(k, "") for k in ins] + [r.get("termos", {}).get(k, "") for k in terms] +
                   [ok.get(t, "") for t in checks] + [r.get("valido", False), r["nota"]])
    return head, out


def _write(path: str, head: list[str], rows: list[list]) -> None:
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, delimiter=SEP)
        w.writerow(head)
        for r in rows:
            w.writerow([_num(v) for v in r])


def run_folder(base: str = "rodadas_aeroopt") -> str:
    """uma pasta nova por rodada: base/AAAA-MM-DD_HHMMSS"""
    return os.path.join(base, time.strftime("%Y-%m-%d_%H%M%S"))


def write(rows: list[dict], folder: str) -> str:
    """grava avaliacoes.csv e configuracoes.csv em `folder` (criada se não existe); devolve a pasta"""
    os.makedirs(folder, exist_ok=True)
    _write(os.path.join(folder, "avaliacoes.csv"), *evaluations(rows))
    _write(os.path.join(folder, "configuracoes.csv"), *configurations(rows))
    return folder
