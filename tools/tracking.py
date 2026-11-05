"""Tracking em HTML: as tabelas do Quadro do docs/TRACKING.md viram uma página só (sem nada para baixar).

    python tools/tracking.py                   # grava a página em zig-out/site/tracking.html
    python tools/tracking.py --html x.html     # em outro lugar
    python tools/tracking.py --check           # só confere se toda linha das tabelas tem as 6 colunas

O TRACKING.md continua sendo a fonte: cada "### segmento" do Quadro, com o parágrafo que o descreve e a tabela
(ID, Tarefa, Tipo, Depende de, Bloco, Estado). Uma tarefa nova é uma linha nova na tabela. A página mostra também a
"Ordem de prioridade" e o "Progresso" do TRACKING.md e as tabelas do docs/AREAS.md (o que cada aba faz e o que já está
em Zig). O tools/web_build.py chama este script, então o site publicado sai sempre do .md da `main`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TRACKING = os.path.join(ROOT, "docs", "TRACKING.md")
AREAS = os.path.join(ROOT, "docs", "AREAS.md")
PAGE = os.path.join(ROOT, "zig-out", "site", "tracking.html")
ROW = re.compile(r"^\| ([A-Z]+[0-9]+) \|")


def cells(line: str) -> list[str]:
    """as células de uma linha de tabela (o texto da tarefa não tem `|`)"""
    return [cell.strip() for cell in line.strip().strip("|").split(" | ")]


def board(text: str) -> tuple[dict, list[str]]:
    """os segmentos do Quadro (nome, descrição, itens) e as linhas com problema"""
    begin = text.index("\n## Quadro")
    end = text.index("\n## ", begin + 1)
    segments: list[dict] = []
    notes: list[str] = []
    problems: list[str] = []
    current = None
    in_table = False
    for line in text[begin:end].split("\n"):
        if line.startswith("### "):
            current = {"nome": line[4:].strip(), "descricao": "", "itens": []}
            segments.append(current)
            in_table = False
            continue
        if current is None:
            continue
        if line.startswith("| ID |") or line.startswith("|---"):
            in_table = True
            continue
        if ROW.match(line):
            parts = cells(line)
            if len(parts) != 6:
                problems.append(f"{parts[0]}: {len(parts)} colunas em vez de 6")
                continue
            ident, task, kind, depends, block, state = parts
            item = {"id": ident, "tarefa": task, "tipo": kind, "bloco": block,
                    "depende": [d.strip() for d in re.split(r"[,;]", depends) if re.match(r"^[A-Z]+[0-9]+$", d.strip())]}
            match = re.match(r"^(.*?) \((.*)\)$", state)
            item["estado"], item["obs"] = (match.group(1), match.group(2)) if match else (state, "")
            current["itens"].append(item)
            continue
        if not line.strip() or line.strip() == "---":
            continue
        if in_table:
            notes.append(line)            # o que vem depois da última tabela (o caminho crítico)
        else:
            current["descricao"] = (current["descricao"] + " " + line.strip()).strip()
    return {"segmentos": segments, "notas": notes}, problems


def section(text: str, title: str) -> str:
    """o corpo de uma seção '## título' do Markdown, até a próxima '## ' ou '---'"""
    match = re.search(rf"^## {re.escape(title)}.*?$(.*?)(?=^## |^---$)", text, re.S | re.M)
    return match.group(1).strip() if match else ""


def page(tracking: str, data: dict) -> str:
    """a página HTML com os dados embutidos; quem desenha é o JavaScript dela"""
    with open(AREAS, encoding="utf-8") as f:
        areas = f.read()
    payload = {
        "segmentos": data["segmentos"],
        "notas": data.get("notas", []),
        "prioridade": section(tracking, "Ordem de prioridade"),
        "progresso": section(tracking, "Progresso da lista"),
        "areas": areas.split("\n", 1)[1].strip(),       # sem o título "# Áreas e submódulos"
    }
    with open(os.path.join(os.path.dirname(__file__), "tracking_page.html"), encoding="utf-8") as f:
        template = f.read()
    blob = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    return template.replace("/*DADOS*/null", blob)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--html", default=PAGE, help="onde gravar a página (padrão: zig-out/site/tracking.html)")
    parser.add_argument("--check", action="store_true", help="só confere as tabelas do Quadro")
    args = parser.parse_args()

    with open(TRACKING, encoding="utf-8") as f:
        text = f.read()
    data, problems = board(text)
    for problem in problems:
        print("docs/TRACKING.md:", problem)
    if args.check:
        print("Quadro do TRACKING.md legível" if not problems else "corrija as linhas acima")
        return 1 if problems else 0
    os.makedirs(os.path.dirname(os.path.abspath(args.html)), exist_ok=True)
    with open(args.html, "w", encoding="utf-8") as f:
        f.write(page(text, data))
    total = sum(len(segment["itens"]) for segment in data["segmentos"])
    print(f"{os.path.relpath(args.html, ROOT)}: {total} tarefas em {len(data['segmentos'])} segmentos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
