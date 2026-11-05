"""Gera `aerosim/model/templates.zig`: os modelos padrão de `aerosim/model/templates.py` como o texto .json que o
Python grava, para o "Restaurar → modelo padrão" da Montagem em Zig. Rodar de novo quando um modelo mudar:

    python tools/templates_zig.py
"""
from __future__ import annotations

import json
import sys
import os
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from aerosim.data.sources import save_aircraft
from aerosim.model.templates import TEMPLATES

OUT = os.path.join(os.path.dirname(__file__), "..", "aerosim", "model", "templates.zig")


def main() -> None:
    lines = [
        "//! Os modelos padrão do avião (`TEMPLATES` de `templates.py`), como o texto .json que o Python grava. Gerado por",
        "//! `python tools/templates_zig.py`; não editar à mão. A Montagem em Zig volta a um deles no \"Restaurar\".",
        "",
        "/// um modelo padrão: o nome que o menu mostra e o texto do arquivo",
        "pub const Template = struct { name: []const u8, json: []const u8 };",
        "",
        "/// os modelos na ordem do menu do Python",
        "pub const all = [_]Template{",
    ]
    with tempfile.TemporaryDirectory() as folder:
        for key, build in TEMPLATES.items():
            ac = build()
            path = os.path.join(folder, f"{key}.json")
            save_aircraft(ac, path)
            with open(path, encoding="utf-8") as f:
                text = json.dumps(json.load(f), ensure_ascii=False, separators=(",", ":"))
            lines.append(f"    .{{ .name = {json.dumps(ac.name, ensure_ascii=False)}, .json = {json.dumps(text, ensure_ascii=False)} }},")
    lines.append("};")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
