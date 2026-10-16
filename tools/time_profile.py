"""Perfil de tempo: onde uma análise gasta o tempo, no Python e no núcleo Zig ao mesmo tempo.

    python tools/time_profile.py envelope                         # uma simulação do manager, com os padrões
    python tools/time_profile.py mission --param mode="curvas: raio mínimo" --aviao flying_wing
    python tools/time_profile.py caminho/script.py                # qualquer script
    python tools/time_profile.py envelope --exato                 # contagem exata (Valgrind/Callgrind), bem mais lento
    python tools/time_profile.py --de-pilhas perfis/x/pilhas.txt  # refaz tabela e flame graph sem amostrar de novo

Saída (pasta `perfis/<alvo>_<data>/`, fora do git):
    pilhas.txt       as pilhas amostradas, no formato "collapsed" (f1;f2;f3 n) — abre no speedscope.app
    chama.svg        flame graph: cada barra é uma função, a largura é a fração do tempo e quem chama fica embaixo
    tabela.txt       por função: tempo próprio, tempo total (com o que ela chama) e % — a mesma tabela é impressa
    modulos.txt      a mesma tabela por módulo (Zig: o arquivo do núcleo, ex. physics/aero.zig; Python: o arquivo .py)
    chama_modulos.svg  flame graph com a pilha resumida a módulos (chamadas seguidas no mesmo módulo viram uma barra)
    *.png            os dois flame graphs também em PNG (precisa do PyQt6)
    callgrind.out    (só com --exato) contagem exata de instruções e de chamadas; abre no KCachegrind

Amostragem: py-spy (`--native`) pausa o processo `--taxa` vezes por segundo e anota a pilha, com os quadros do Python
e os nativos (o núcleo, chamado por ctypes). O tempo de cada função é estimado pelas amostras (n / taxa). Para os
nomes das funções do Zig aparecerem, o núcleo é recompilado com símbolos (`-Dstrip=false`; as contas não mudam) e
volta a ser compilado como antes no fim (`--manter-simbolos` deixa como está).

Flame graph: Gregg, B., "The Flame Graph", Communications of the ACM 59(6), 48–57, 2016.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import html
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CORE = os.path.join(ROOT, "core")


# ---------------------------------------------------------------------- leitura das pilhas (funções puras)
def frame_name(frame: str) -> str:
    """'f (arquivo.py:12)' -> 'f (arquivo.py)': o mesmo nome em linhas diferentes conta junto"""
    return re.sub(r"(\([^()]*?):\d+\)$", r"\1)", frame.strip())


def read_collapsed(text: str) -> list[tuple[list[str], int]]:
    """linhas 'f1;f2;f3 n' (n amostras da pilha f1 → f3, da raiz para a folha)"""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        stack, _, n = line.rpartition(" ")
        if not stack or not n.isdigit():
            continue
        out.append(([frame_name(f) for f in stack.split(";") if f], int(n)))
    return out


HEX = re.compile(r"^0x[0-9a-f]+ \(")
IMPORT = ("_find_and_load", "_handle_fromlist", "_call_with_frames_removed")


def clean(stacks: list[tuple[list[str], int]], keep_imports: bool = False):
    """tira os quadros nativos sem nome (endereço: o tempo fica com quem chamou, ex.: o interpretador do Python) e,
    sem `keep_imports`, separa as pilhas que estão importando módulos (o tempo de carregar, não o da análise).
    Devolve (pilhas, amostras de importação)"""
    out, imp = [], 0
    for frames, n in stacks:
        fr = [f for f in frames if not HEX.match(f)]
        if not keep_imports and any(f.startswith(IMPORT) for f in fr):
            imp += n
            continue
        if fr:
            out.append((fr, n))
    return out, imp


def table(stacks: list[tuple[list[str], int]]) -> list[dict]:
    """por função: amostras próprias (é a folha da pilha), totais (aparece na pilha; contada uma vez por pilha,
    mesmo com recursão) e as frações do total; ordenada pelo total"""
    own, tot = defaultdict(int), defaultdict(int)
    total = 0
    for frames, n in stacks:
        total += n
        if frames:
            own[frames[-1]] += n
        for f in set(frames):
            tot[f] += n
    rows = [dict(funcao=f, proprio=own[f], total=tot[f], proprio_pct=100.0 * own[f] / total if total else 0.0,
                 total_pct=100.0 * tot[f] / total if total else 0.0) for f in tot]
    rows.sort(key=lambda r: (-r["total"], -r["proprio"], r["funcao"]))
    return rows


def format_table(rows: list[dict], rate: float, top: int = 30) -> str:
    """tabela de texto; o tempo é n / taxa (s)"""
    lines = [f"{'total (s)':>10} {'total %':>8} {'próprio (s)':>12} {'próprio %':>10}  função"]
    for r in rows[:top]:
        lines.append(f"{r['total'] / rate:10.3f} {r['total_pct']:7.1f}% {r['proprio'] / rate:12.3f} "
                     f"{r['proprio_pct']:9.1f}%  {r['funcao']}")
    return "\n".join(lines)


def module_of(frame: str) -> str:
    """módulo de um quadro: no Zig, o caminho do nome até o arquivo ('physics.aero.clPanel (aero.zig)' ->
    'physics/aero.zig'); no Python, o arquivo ('f (aerosim/model/universal.py)' -> 'aerosim/model/universal.py');
    nas bibliotecas nativas, a biblioteca ('ffi_call (libffi.so.8.1.4)' -> 'libffi.so.8.1.4')"""
    m = re.match(r"^(.*) \(([^()]*)\)$", frame.strip())
    if not m:
        return frame.strip()
    name, where = m.groups()
    if where.endswith(".zig"):
        stem = where[:-4]
        parts = name.split(".")
        if stem in parts:
            return "/".join(parts[: parts.index(stem) + 1]) + ".zig"
        return where
    return where


def module_stacks(stacks: list[tuple[list[str], int]]) -> list[tuple[list[str], int]]:
    """as pilhas com cada quadro trocado pelo seu módulo; quadros seguidos do mesmo módulo viram um"""
    out = []
    for frames, n in stacks:
        mods = []
        for f in frames:
            md = module_of(f)
            if not mods or mods[-1] != md:
                mods.append(md)
        out.append((mods, n))
    return out


def svg_to_png(svg_path: str, png_path: str, scale: float = 1.5) -> bool:
    """SVG -> PNG pelo renderizador do Qt (sem tela); False se o PyQt6 não estiver disponível"""
    try:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        from PyQt6 import QtGui, QtSvg
    except ImportError:
        return False
    app = QtGui.QGuiApplication.instance() or QtGui.QGuiApplication([])  # noqa: F841 (o Qt precisa de uma)
    r = QtSvg.QSvgRenderer(svg_path)
    img = QtGui.QImage(r.defaultSize() * scale, QtGui.QImage.Format.Format_ARGB32)
    img.fill(QtGui.QColor("white"))
    p = QtGui.QPainter(img)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    r.render(p)
    p.end()
    return img.save(png_path)


def _tree(stacks):
    root = {"n": 0, "kids": {}}
    for frames, n in stacks:
        root["n"] += n
        node = root
        for f in frames:
            node = node["kids"].setdefault(f, {"n": 0, "kids": {}})
            node["n"] += n
    return root


def _color(name: str) -> str:
    """cores quentes (Gregg): núcleo/nativo em laranja, Python em amarelo; o tom varia com o nome, sem significado"""
    h = sum(map(ord, name)) % 40
    py = name.endswith((".py", ".py)")) or "(<frozen" in name or name.startswith("<frozen")
    native = not py
    return f"rgb(230,{90 + h},40)" if native else f"rgb(235,{170 + h},60)"


def flame_svg(stacks: list[tuple[list[str], int]], title: str = "", width: int = 1600, row: int = 17) -> str:
    """flame graph em SVG (a raiz embaixo, as folhas em cima); passar o mouse mostra a função e a fração"""
    root = _tree(stacks)
    total = max(root["n"], 1)
    rects = []
    depth_max = [0]

    def walk(node, x, depth):
        depth_max[0] = max(depth_max[0], depth)
        for name, kid in sorted(node["kids"].items()):
            w = width * kid["n"] / total
            if w >= 0.3:
                rects.append((x, depth, w, name, kid["n"]))
                walk(kid, x, depth + 1)
            x += w
    walk(root, 0.0, 0)
    height = (depth_max[0] + 2) * row + 30
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" font-family="monospace" '
           f'font-size="11"><rect width="100%" height="100%" fill="#fff"/>',
           f'<text x="6" y="16" font-size="13">{html.escape(title)} — {total} amostras</text>']
    for x, depth, w, name, n in rects:
        y = height - (depth + 1) * row
        tip = html.escape(f"{name} — {n} amostras ({100.0 * n / total:.1f} %)")
        label = html.escape(name[: int(w / 6.6)]) if w > 20 else ""
        out.append(f'<g><title>{tip}</title><rect x="{x:.2f}" y="{y}" width="{max(w - 0.5, 0.1):.2f}" '
                   f'height="{row - 1}" fill="{_color(name)}"/>'
                   f'<text x="{x + 3:.2f}" y="{y + row - 5}">{label}</text></g>')
    out.append("</svg>")
    return "\n".join(out)


# ---------------------------------------------------------------------- o que roda dentro do perfil
def _runner_code(target: str, aircraft: str, params: dict) -> str:
    """script que o py-spy/Callgrind executa: uma simulação do manager ou o script pedido"""
    if target.endswith(".py"):
        return f"import runpy, sys; sys.argv = [{target!r}]; runpy.run_path({target!r}, run_name='__main__')"
    return (f"import sys; sys.path.insert(0, {ROOT!r})\n"
            "from aerosim.backend.zig import ZigBackend\n"
            "from aerosim.manager import SimulationManager\n"
            "from aerosim.model.templates import TEMPLATES\n"
            "from aerosim.data import load_aircraft\n"
            f"a = {aircraft!r}\n"
            "ac = TEMPLATES[a]() if a in TEMPLATES else load_aircraft(a)\n"
            f"r = SimulationManager(ZigBackend()).run({target!r}, ac, {params!r})\n"
            "print('status:', r.status)\n")


def _build_core(strip: bool, fast_math: bool = True) -> None:
    cmd = [sys.executable, "-m", "ziglang", "build", "--release=fast", f"-Dfast_math={'true' if fast_math else 'false'}",
           f"-Dstrip={'true' if strip else 'false'}"]
    subprocess.run(cmd, cwd=CORE, check=True)


def _parse_params(items: list[str]) -> dict:
    out = {}
    for it in items or []:
        k, _, v = it.partition("=")
        try:
            out[k] = float(v) if v.replace(".", "", 1).replace("-", "", 1).isdigit() else v
        except ValueError:
            out[k] = v
    return out


def _report(raw: str, out: str, rate: float, top: int, title: str, keep_imports: bool = False) -> int:
    """pilhas.txt -> tabela.txt e chama.svg na pasta `out`; imprime a tabela"""
    with open(raw, encoding="utf-8") as f:
        stacks, imp = clean(read_collapsed(f.read()), keep_imports)
    rows = table(stacks)
    n = sum(c for _, c in stacks)
    head = (f"{title}: {n} amostras na análise ({n / rate:.2f} s)"
            + (f"; importando módulos: {imp} amostras ({imp / rate:.2f} s, fora da tabela; --com-import inclui)"
               if imp else ""))
    with open(os.path.join(out, "tabela.txt"), "w", encoding="utf-8") as f:
        f.write(head + "\n\n" + format_table(rows, rate, top=len(rows)) + "\n")
    with open(os.path.join(out, "chama.svg"), "w", encoding="utf-8") as f:
        f.write(flame_svg(stacks, title=title))
    ms = module_stacks(stacks)
    mrows = table(ms)
    with open(os.path.join(out, "modulos.txt"), "w", encoding="utf-8") as f:
        own = sorted(mrows, key=lambda r: (-r["proprio"], r["funcao"]))
        f.write(head + "\n\npelo tempo próprio (onde a CPU fica):\n"
                + format_table([r for r in own if r["proprio"]], rate, top=len(own)).replace("função", "módulo")
                + "\n\npelo tempo total (com o que o módulo chama):\n"
                + format_table(mrows, rate, top=len(mrows)).replace("função", "módulo") + "\n")
    with open(os.path.join(out, "chama_modulos.svg"), "w", encoding="utf-8") as f:
        f.write(flame_svg(ms, title=f"{title} — por módulo"))
    for name in ("chama", "chama_modulos"):
        svg_to_png(os.path.join(out, f"{name}.svg"), os.path.join(out, f"{name}.png"))
    print(head + "\n\n" + format_table(rows, rate, top))
    print("\npor módulo:\n" + format_table(mrows, rate, top).replace("função", "módulo"))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="perfil de tempo de uma simulação do manager ou de um script")
    ap.add_argument("alvo", nargs="?", default="",
                    help="nome da simulação (mission, envelope, performance, loads...) ou um .py")
    ap.add_argument("--de-pilhas", default=None, help="só refaz a tabela e o flame graph de um pilhas.txt já gravado")
    ap.add_argument("--aviao", default="conventional",
                    help="template (conventional, flying_wing, twin_boom) ou arquivo")
    ap.add_argument("--param", action="append", default=[], help="parâmetro da simulação, chave=valor (repetível)")
    ap.add_argument("--taxa", type=float, default=100.0, help="amostras por segundo (py-spy; mais alta deixa a "
                    "rodada mais lenta, porque cada amostra nativa pausa o processo)")
    ap.add_argument("--com-import", action="store_true", help="inclui o tempo de importar os módulos na tabela")
    ap.add_argument("--top", type=int, default=30, help="linhas da tabela")
    ap.add_argument("--saida", default=None, help="pasta de saída (padrão: perfis/<alvo>_<data>/)")
    ap.add_argument("--exato", action="store_true", help="também a contagem exata pelo Valgrind/Callgrind (lento)")
    ap.add_argument("--manter-simbolos", action="store_true", help="não recompila o núcleo sem símbolos no fim")
    ap.add_argument("--std-math", action="store_true", help="núcleo com as funções da std (-Dfast_math=false) em vez "
                    "das tabelas do fmath, para comparar; no fim volta ao padrão")
    args = ap.parse_args(argv)
    if args.de_pilhas:
        return _report(args.de_pilhas, os.path.dirname(os.path.abspath(args.de_pilhas)), args.taxa, args.top,
                       os.path.basename(os.path.dirname(os.path.abspath(args.de_pilhas))), args.com_import)
    if not args.alvo:
        ap.error("diga o alvo (uma simulação ou um .py) ou use --de-pilhas")

    if shutil.which("py-spy") is None:
        print("py-spy não encontrado: pip install py-spy", file=sys.stderr)
        return 2
    tag = os.path.splitext(os.path.basename(args.alvo))[0]
    out = args.saida or os.path.join(ROOT, "perfis", f"{tag}_{_dt.datetime.now():%Y%m%d_%H%M%S}")
    os.makedirs(out, exist_ok=True)
    code = _runner_code(os.path.abspath(args.alvo) if args.alvo.endswith(".py") else args.alvo, args.aviao,
                        _parse_params(args.param))
    script = os.path.join(out, "alvo.py")
    with open(script, "w", encoding="utf-8") as f:
        f.write(code)

    print(f"núcleo com símbolos (-Dstrip=false{', -Dfast_math=false' if args.std_math else ''})…", flush=True)
    _build_core(strip=False, fast_math=not args.std_math)
    try:
        raw = os.path.join(out, "pilhas.txt")
        print(f"amostrando {args.alvo} a {args.taxa:g} Hz…", flush=True)
        r = subprocess.run(["py-spy", "record", "--native", "-r", f"{args.taxa:g}", "-f", "raw", "-o", raw, "--",
                            sys.executable, script], cwd=ROOT)
        if not os.path.exists(raw) or os.path.getsize(raw) == 0:
            print("py-spy falhou: nenhuma amostra gravada", file=sys.stderr)
            return 1
        if r.returncode != 0:                   # ex.: "No child process" ao sair, depois de gravar tudo
            print(f"(o py-spy saiu com código {r.returncode} depois de gravar as amostras; seguindo)", flush=True)
        title = args.alvo if args.alvo.endswith(".py") else f"{args.alvo} ({args.aviao})"
        _report(raw, out, args.taxa, args.top, title, args.com_import)
        if args.exato:
            if shutil.which("valgrind") is None:
                print("valgrind não encontrado: o --exato fica de fora", file=sys.stderr)
            else:
                cg = os.path.join(out, "callgrind.out")
                print("contagem exata (Callgrind), bem mais lento…", flush=True)
                subprocess.run(["valgrind", "--tool=callgrind", f"--callgrind-out-file={cg}", sys.executable, script],
                               cwd=ROOT)
                ann = subprocess.run(["callgrind_annotate", "--inclusive=yes", "--threshold=100", cg],
                                     capture_output=True, text=True)
                with open(os.path.join(out, "callgrind.txt"), "w", encoding="utf-8") as f:
                    f.write(ann.stdout)
                lines = ann.stdout.splitlines()
                k = next((i for i, ln in enumerate(lines) if "file:function" in ln), 0)
                print("\n".join(lines[max(k - 4, 0):k + 1 + args.top]))
                # no Python, o interpretador é recursivo e o inclusivo passa de 100 %: o que interessa é o núcleo
                core = [ln for ln in lines[k + 1:] if "libaerosim" in ln or ".zig:" in ln][:args.top]
                if core:
                    print("\nsó o núcleo (instruções inclusivas, função):")
                    print("\n".join(core))
        print(f"\nsaída em {out}")
    finally:
        if not args.manter_simbolos or args.std_math:
            print("núcleo de volta como antes (sem símbolos, fast_math)…", flush=True)
            _build_core(strip=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
