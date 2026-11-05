"""Tracking em HTML: as tabelas do Quadro do docs/TRACKING.md viram uma página só (sem nada para baixar).

    python tools/tracking.py                   # grava a página em zig-out/site/tracking.html
    python tools/tracking.py --html x.html     # em outro lugar
    python tools/tracking.py --check           # só confere se toda linha das tabelas tem as 6 colunas
    python tools/tracking.py --feito G26 dc19cf2   # marca a tarefa como Feito, com o commit (sem ele, o HEAD)
    python tools/tracking.py --estado G27 "Em andamento"
    python tools/tracking.py --issue corpo.txt     # aplica uma issue "[tracking] ..." (o que a Action faz)

O TRACKING.md continua sendo a fonte: cada "### segmento" do Quadro, com o parágrafo que o descreve e a tabela
(ID, Tarefa, Tipo, Depende de, Bloco, Estado). Uma tarefa nova é uma linha nova na tabela. Uma tarefa resolvida
fica "Feito (commit abc1234)": a página risca o título, põe o link do commit e tira a tarefa da sequência dos
próximos (dá para escrever à mão ou com `--feito`).

A página também muda o .md sem colar nada: "Confirmar feito" e "+ Nova tarefa" abrem uma issue "[tracking] ..." já
preenchida, e a Action .github/workflows/tracking.yml (só para issues do dono do repositório) roda `--issue` com o
corpo dela, faz o commit na 0.2_dev e fecha a issue. O corpo é "chave: valor" por linha (acao feito|nova, id, commit,
segmento, tipo, depende, bloco, estado), depois "---" e o texto livre. A página mostra também a
"Ordem de prioridade" e o "Progresso" do TRACKING.md e as tabelas do docs/AREAS.md (o que cada aba faz e o que já está
em Zig). O tools/web_build.py chama este script, então o site publicado sai sempre do .md da `main`.
"""
from __future__ import annotations

import argparse
import datetime
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


def set_state(text: str, ident: str, state: str) -> str:
    """o TRACKING.md com a coluna Estado da tarefa `ident` trocada por `state`"""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith(f"| {ident} |"):
            parts = cells(line)
            if len(parts) != 6:
                sys.exit(f"{ident}: a linha não tem as 6 colunas")
            parts[5] = state
            lines[i] = "| " + " | ".join(parts) + " |"
            return "\n".join(lines)
    sys.exit(f"{ident}: não está no Quadro")


def read_issue(body: str) -> dict:
    """os campos do corpo de uma issue do tracking (o mesmo formato que a página escreve)"""
    head, _, rest = body.replace("\r", "").partition("\n---\n")
    fields = {}
    for line in head.split("\n"):
        match = re.match(r"^(\w+):\s*(.*)$", line)
        if match:
            fields[match.group(1)] = match.group(2).strip()
    fields["texto"] = re.sub(r"\s+", " ", rest).replace("|", "/").strip()
    return fields


def next_id(text: str, segment: str) -> str:
    """o próximo número livre: O no aeroopt, G na GUI, T no resto (um contador só para os outros segmentos)"""
    prefix = "O" if segment == "aeroopt" else "G" if segment == "GUI" else "T"
    numbers = [int(m.group(1)) for m in re.finditer(rf"^\| {prefix}([0-9]+) \|", text, re.M)]
    return f"{prefix}{max(numbers, default=0) + 1:02d}"


def apply_issue(text: str, fields: dict) -> tuple[str, str]:
    """o TRACKING.md com a mudança da issue e uma linha dizendo o que mudou"""
    action = fields.get("acao")
    if action == "feito":
        ident = fields.get("id", "")
        lines = text.split("\n")
        for i, line in enumerate(lines):
            if line.startswith(f"| {ident} |"):
                parts = cells(line)
                if fields["texto"]:
                    parts[1] += f" Feito: {fields['texto']}"
                parts[5] = f"Feito (commit {fields['commit']})" if fields.get("commit") else "Feito"
                lines[i] = "| " + " | ".join(parts) + " |"
                return "\n".join(lines), f"{ident} feito"
        sys.exit(f"{ident}: não está no Quadro")
    if action == "nova":
        segment = fields.get("segmento", "")
        heading = text.find(f"\n### {segment}\n", text.index("\n## Quadro"))
        if heading < 0:
            sys.exit(f"segmento '{segment}' não existe no Quadro")
        lines = text[heading + 1:].split("\n")
        last = max(i for i, line in enumerate(lines[:next((k for k, l in enumerate(lines[1:], 1) if l.startswith("#")), len(lines))])
                   if ROW.match(line))
        ident = next_id(text, segment)
        depends = ", ".join(d for d in re.split(r"[,;\s]+", fields.get("depende", "").upper()) if re.match(r"^[A-Z]+[0-9]+$", d)) or "—"
        row = (f"| {ident} | {fields['texto'] or '(sem texto)'} | {fields.get('tipo') or '[ext]'} | {depends} | "
               f"{fields.get('bloco') or '—'} | {fields.get('estado') or 'A fazer'} |")
        lines.insert(last + 1, row)
        return text[:heading + 1] + "\n".join(lines), f"{ident} nova em {segment}"
    sys.exit(f"ação desconhecida: {action!r} (feito ou nova)")


def head_commit() -> str:
    import subprocess
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True,
                          check=True).stdout.strip()


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
        "gerado": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(os.path.dirname(__file__), "tracking_page.html"), encoding="utf-8") as f:
        template = f.read()
    blob = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    return template.replace("/*DADOS*/null", blob)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--html", default=PAGE, help="onde gravar a página (padrão: zig-out/site/tracking.html)")
    parser.add_argument("--check", action="store_true", help="só confere as tabelas do Quadro")
    parser.add_argument("--feito", nargs="+", metavar=("ID", "COMMIT"), help="marca a tarefa como Feito (commit; padrão: HEAD)")
    parser.add_argument("--estado", nargs=2, metavar=("ID", "ESTADO"), help="troca o estado da tarefa")
    parser.add_argument("--issue", metavar="ARQUIVO", help="aplica o corpo de uma issue do tracking")
    args = parser.parse_args()

    with open(TRACKING, encoding="utf-8") as f:
        text = f.read()
    if args.feito or args.estado:
        if args.feito:
            ident = args.feito[0]
            state = f"Feito (commit {args.feito[1] if len(args.feito) > 1 else head_commit()})"
        else:
            ident, state = args.estado
        text = set_state(text, ident, state)
        with open(TRACKING, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"docs/TRACKING.md: {ident} → {state}")
    if args.issue:
        with open(args.issue, encoding="utf-8") as f:
            text, summary = apply_issue(text, read_issue(f.read()))
        with open(TRACKING, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"docs/TRACKING.md: {summary}")
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
