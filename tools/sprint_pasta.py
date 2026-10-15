"""Exemplo: converte um projeto da sprint antigo (um .json só) para a pasta nova, um arquivo por asa.

    python tools/sprint_pasta.py                                         # o exemplo S1223 → ./sprint_s1223/
    python tools/sprint_pasta.py data/sprint/projeto_s1223.json ~/sprint # escolhendo origem e destino

O arquivo de origem não é alterado, e nada é gravado dentro de data/. Mostra o que foi para cada arquivo.
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)

from aerosim.design import store  # noqa: E402

SAMPLE = os.path.join(ROOT, "data", "sprint", "projeto_s1223.json")


def convert(src: str, dst: str) -> list[str]:
    """grava `src` em `dst` no formato de pasta; devolve as linhas do resumo"""
    if os.path.abspath(dst).startswith(os.path.join(ROOT, "data") + os.sep):
        raise SystemExit("não gravo dentro de data/: escolha outra pasta")
    p, _ = store.open_path(src)
    store.save(p, dst)
    lines = [f"{src}  →  {dst}/"]
    for n in sorted(os.listdir(dst)):
        with open(os.path.join(dst, n), encoding="utf-8") as f:
            d = json.load(f)
        if d.get("format") == store.WING_KIND:
            sup = " | ".join(s["params"]["name"] for s in d["superficies"]) or "—"
            avi = " | ".join(a["params"]["name"] + (" (cópia antiga da superfície)" if "superficie_copia" in a else "")
                            for a in d["avioes"]) or "—"
            lines += [f"  {n}", f"    asa:         {d['nome']}", f"    superfícies: {sup}", f"    aviões:      {avi}"]
        else:
            lines += [f"  {n}", f"    perfis: {', '.join(a['airfoil']['name'] for a in d['airfoils'])}",
                      f"    estudos: {len(d['studies'])}, Montagem: {len(d['fleet'])} avião(ões)"]
    return lines


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    src = argv[0] if argv else SAMPLE
    dst = argv[1] if len(argv) > 1 else os.path.join(os.getcwd(), "sprint_" + os.path.splitext(os.path.basename(src))[0]
                                                                     .replace("projeto_", ""))
    print("\n".join(convert(src, dst)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
