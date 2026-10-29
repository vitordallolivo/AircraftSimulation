"""Monta o site do AircraftSimulation em zig-out/site/: a tela inicial (web/index.html) e o AeroDrive em WebAssembly.

    python tools/web_build.py                 # compila o AeroDrive para o navegador e monta o site
    python tools/web_build.py --sem-compilar  # só monta, com o que já está em aerodrive/zig-out/web
    python -m http.server -d zig-out/site 8000   # e abrir http://localhost:8000

Os caminhos dentro do site são relativos (index.html -> aerodrive.html -> aerodrive.js/.wasm/.data), então a mesma
pasta serve na raiz de um servidor ou numa subpasta, como https://<usuario>.github.io/AircraftSimulation/.
O GitHub Actions (.github/workflows/site.yml) roda este script e publica a pasta no GitHub Pages.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AERODRIVE = os.path.join(ROOT, "aerodrive")
AERODRIVE_WEB = os.path.join(AERODRIVE, "zig-out", "web")
LAUNCHER = os.path.join(ROOT, "web", "index.html")
SITE = os.path.join(ROOT, "zig-out", "site")
AERODRIVE_FILES = ("aerodrive.html", "aerodrive.js", "aerodrive.wasm", "aerodrive.data")


def build_aerodrive() -> None:
    """Compila o AeroDrive para wasm32-emscripten (saída em aerodrive/zig-out/web)."""
    command = [sys.executable, "-m", "ziglang", "build", "-Dtarget=wasm32-emscripten"]
    print("compilando o AeroDrive para o navegador:", " ".join(command[2:]))
    subprocess.run(command, cwd=AERODRIVE, check=True)


def assemble() -> None:
    """Copia a tela inicial e os arquivos do AeroDrive para zig-out/site (apaga a montagem anterior)."""
    missing = [name for name in AERODRIVE_FILES if not os.path.isfile(os.path.join(AERODRIVE_WEB, name))]
    if missing:
        sys.exit(f"faltam em {os.path.relpath(AERODRIVE_WEB, ROOT)}: {', '.join(missing)} (rode sem --sem-compilar)")
    shutil.rmtree(SITE, ignore_errors=True)
    os.makedirs(SITE)
    shutil.copy2(LAUNCHER, os.path.join(SITE, "index.html"))
    for name in AERODRIVE_FILES:
        shutil.copy2(os.path.join(AERODRIVE_WEB, name), os.path.join(SITE, name))
    # o GitHub Pages não passa a pasta pelo Jekyll (que esconderia arquivos e atrasaria a publicação)
    open(os.path.join(SITE, ".nojekyll"), "w").close()
    total = sum(os.path.getsize(os.path.join(SITE, name)) for name in os.listdir(SITE))
    print(f"site montado em {os.path.relpath(SITE, ROOT)} ({total / 2**20:.1f} MiB):")
    for name in sorted(os.listdir(SITE)):
        print(f"  {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sem-compilar", action="store_true", help="usa o AeroDrive já compilado")
    options = parser.parse_args()
    if not options.sem_compilar:
        build_aerodrive()
    assemble()


if __name__ == "__main__":
    main()
