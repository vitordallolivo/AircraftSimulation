"""Tracking em HTML: o quadro de tarefas sai de docs/tracking.json e vira uma página só (sem nada para baixar) e a
seção "Quadro" do docs/TRACKING.md.

    python tools/tracking.py                   # refaz o Quadro do TRACKING.md e a página zig-out/site/tracking.html
    python tools/tracking.py --html x.html     # a página em outro lugar
    python tools/tracking.py --check           # só confere se o TRACKING.md está igual ao tracking.json

O docs/tracking.json é a fonte das tarefas: segmentos (aerosim, GUI, core...), cada um com a descrição e os itens
(id, tarefa, tipo, depende, bloco, estado e uma observação opcional). O resto do TRACKING.md (prioridade, versões,
itens por área) continua escrito à mão, e a página mostra também a "Ordem de prioridade" dele e as tabelas do
docs/AREAS.md (o que cada aba faz e o que já está em Zig). O tools/web_build.py chama este script para pôr a página
no site.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE = os.path.join(ROOT, "docs", "tracking.json")
TRACKING = os.path.join(ROOT, "docs", "TRACKING.md")
AREAS = os.path.join(ROOT, "docs", "AREAS.md")
PAGE = os.path.join(ROOT, "zig-out", "site", "tracking.html")

BEGIN = "<!-- quadro: gerado por tools/tracking.py a partir de docs/tracking.json; editar o json, não aqui -->"
END = "<!-- fim do quadro gerado -->"


def load() -> dict:
    with open(SOURCE, encoding="utf-8") as f:
        return json.load(f)


def item_row(item: dict) -> str:
    """uma linha da tabela do Quadro, igual à que se escrevia à mão"""
    state = item["estado"] + (f" ({item['obs']})" if item.get("obs") else "")
    depends = ", ".join(item["depende"]) or "—"
    return f"| {item['id']} | {item['tarefa']} | {item['tipo']} | {depends} | {item['bloco']} | {state} |"


def board_markdown(data: dict) -> str:
    """a parte gerada do Quadro: uma tabela por segmento e as notas do fim"""
    parts = [BEGIN, ""]
    for segment in data["segmentos"]:
        parts += [f"### {segment['nome']}", "", segment["descricao"], "",
                  "| ID | Tarefa | Tipo | Depende de | Bloco | Estado |", "|---|---|---|---|---|---|"]
        parts += [item_row(item) for item in segment["itens"]]
        parts.append("")
    for note in data.get("notas", []):
        parts += [note, ""]
    parts.append(END)
    return "\n".join(parts)


def tracking_with_board(text: str, board: str) -> str:
    """o TRACKING.md com o Quadro trocado pelo gerado"""
    begin, end = text.index(BEGIN), text.index(END) + len(END)
    return text[:begin] + board + text[end:]


def section(text: str, title: str) -> str:
    """o corpo de uma seção '## título' do Markdown, até a próxima '## ' ou '---'"""
    match = re.search(rf"^## {re.escape(title)}.*?$(.*?)(?=^## |^---$)", text, re.S | re.M)
    return match.group(1).strip() if match else ""


def page(data: dict) -> str:
    """a página HTML com os dados embutidos; quem desenha é o JavaScript dela"""
    with open(TRACKING, encoding="utf-8") as f:
        tracking = f.read()
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
    parser.add_argument("--check", action="store_true", help="só confere o Quadro do TRACKING.md")
    args = parser.parse_args()

    data = load()
    with open(TRACKING, encoding="utf-8") as f:
        text = f.read()
    updated = tracking_with_board(text, board_markdown(data))
    if args.check:
        if updated != text:
            print("o Quadro do docs/TRACKING.md não bate com docs/tracking.json: rode python tools/tracking.py")
            return 1
        print("Quadro do TRACKING.md em dia")
        return 0
    if updated != text:
        with open(TRACKING, "w", encoding="utf-8") as f:
            f.write(updated)
        print("docs/TRACKING.md: Quadro refeito")
    os.makedirs(os.path.dirname(os.path.abspath(args.html)), exist_ok=True)
    with open(args.html, "w", encoding="utf-8") as f:
        f.write(page(data))
    total = sum(len(segment["itens"]) for segment in data["segmentos"])
    print(f"{os.path.relpath(args.html, ROOT)}: {total} tarefas em {len(data['segmentos'])} segmentos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
