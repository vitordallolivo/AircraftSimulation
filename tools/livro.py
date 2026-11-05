"""Livro do projeto: todos os .md do repositório num site só, como capítulos de um livro, ao lado do tracking.

    python tools/livro.py                      # grava zig-out/site/livro.html, as imagens e o tracking.html
    python tools/livro.py --saida pasta        # em outra pasta
    python -m http.server -d zig-out/site 8000 # e abrir http://localhost:8000/livro.html

Os capítulos se acham sozinhos: todo .md que está no git (fora de `data/` e do próprio TRACKING.md, que é a aba
Tracking) entra, agrupado pela pasta de cima (Projeto, aerosim, Núcleo, AeroDrive, aeroopt, Ferramentas e testes).
Dentro de cada grupo, o README da pasta vem antes do que está dentro dela. O título de cada página é o primeiro
"# título" do arquivo. Um .md novo aparece no livro sem mexer em nada aqui.

A página é uma só (livro.html), com o texto dos .md embutido; quem desenha é o navegador, com o marked (Markdown), o
KaTeX (as equações em ```math e $...$) e o mermaid (os diagramas). As imagens que os .md citam são copiadas para
livro/<caminho no repositório>, e os links entre .md viram links dentro do livro. O tools/web_build.py chama este
script para montar o site.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SITE = os.path.join(ROOT, "zig-out", "site")
TEMPLATE = os.path.join(os.path.dirname(__file__), "livro_page.html")
GITHUB = "https://github.com/vitordallolivo/AircraftSimulation/blob/main/"

# grupos do livro, na ordem: (nome, prefixos de caminho); o primeiro que casa leva o arquivo
GROUPS = (
    ("Projeto", ("README.md", "ideias.md", "CHANGELOG.md", ".claude/", "docs/")),
    ("aerosim", ("aerosim/",)),
    ("Núcleo (core)", ("core/",)),
    ("AeroDrive", ("aerodrive/",)),
    ("aeroopt", ("aeroopt/",)),
    ("Ferramentas e testes", ("tools/", "tests/", "launcher/")),
)
LEFT_OUT = ("docs/TRACKING.md",)           # o tracking tem a aba própria
IMAGE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)")


def markdown_files() -> list[str]:
    """os .md que estão no git, fora de data/"""
    listed = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [path for path in listed.split() if not path.startswith("data/") and path not in LEFT_OUT]


def group_of(path: str) -> str:
    for name, prefixes in GROUPS:
        if any(path == prefix or path.startswith(prefix) for prefix in prefixes):
            return name
    return "Outros"


def order_key(path: str) -> tuple:
    """o README da pasta antes do resto dela; as pastas em ordem alfabética"""
    folder, name = os.path.split(path)
    return (folder.split("/"), 0 if name.upper().startswith("README") else 1, name)


def title_of(text: str, path: str) -> str:
    """o primeiro "# título", sem a pasta na frente ("aerosim/aero — aerodinâmica" vira "Aerodinâmica"): onde o
    arquivo está é assunto do docs/MAP.md"""
    match = re.search(r"^# (.+)$", text, re.M)
    if not match:
        return path
    title = re.sub(r"^`?[\w./-]+/[\w./-]*`?\s+[—–-]\s+", "", match.group(1).strip())
    title = re.sub(r"\s*\(`[\w./-]+/`\)$", "", title)
    return title[:1].upper() + title[1:]


def book(paths: list[str]) -> dict:
    """os capítulos (grupo → páginas) com o texto de cada .md"""
    chapters: dict[str, list[dict]] = {name: [] for name, _ in GROUPS}
    chapters["Outros"] = []
    for path in sorted(paths, key=order_key):
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            text = f.read()
        title = title_of(text, path)
        text = re.sub(r"^# .+$", lambda _: "# " + title, text, count=1, flags=re.M)   # o título simples no texto também
        chapters[group_of(path)].append({"caminho": path, "titulo": title, "md": text})
    # o README da raiz abre o livro
    first = chapters["Projeto"]
    first.sort(key=lambda page: (page["caminho"] != "README.md", order_key(page["caminho"])))
    return {"grupos": [{"nome": name, "paginas": pages} for name, pages in chapters.items() if pages],
            "github": GITHUB}


def copy_images(pages: list[dict], target: str) -> int:
    """copia as imagens citadas pelos .md para livro/<caminho no repositório>; devolve quantas"""
    count = 0
    for page in pages:
        folder = os.path.dirname(page["caminho"])
        for reference in IMAGE.findall(page["md"]):
            if re.match(r"^[a-z]+:", reference):
                continue
            source = os.path.normpath(os.path.join(ROOT, folder, reference.split("#")[0]))
            if not source.startswith(ROOT) or not os.path.isfile(source):
                continue
            destination = os.path.join(target, "livro", os.path.relpath(source, ROOT))
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copy2(source, destination)
            count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--saida", default=SITE, help="pasta do site (padrão: zig-out/site)")
    args = parser.parse_args()

    data = book(markdown_files())
    os.makedirs(args.saida, exist_ok=True)
    with open(TEMPLATE, encoding="utf-8") as f:
        template = f.read()
    blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    with open(os.path.join(args.saida, "livro.html"), "w", encoding="utf-8") as f:
        f.write(template.replace("/*LIVRO*/null", blob))
    pages = [page for group in data["grupos"] for page in group["paginas"]]
    images = copy_images(pages, args.saida)
    # a aba Tracking: a página do tracking ao lado do livro
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "tracking.py"), "--html",
                    os.path.join(args.saida, "tracking.html")], check=True)
    print(f"{os.path.relpath(os.path.join(args.saida, 'livro.html'), ROOT)}: {len(pages)} páginas em "
          f"{len(data['grupos'])} grupos, {images} imagens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
