"""Monta o site do AircraftSimulation em zig-out/site/: a tela inicial (web/index.html) e os três programas em
WebAssembly (AeroDrive, aerosim e aeroopt).

    python tools/web_build.py                 # compila os três para o navegador e monta o site
    python tools/web_build.py --sem-compilar  # só monta, com o que já está em <programa>/zig-out/web
    python -m http.server -d zig-out/site 8000   # e abrir http://localhost:8000

Os caminhos dentro do site são relativos (index.html -> aerodrive.html -> aerodrive.js/.wasm/.data; o mesmo para o
aerosim e o aeroopt), então a mesma
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
LAUNCHER = os.path.join(ROOT, "web", "index.html")
SITE = os.path.join(ROOT, "zig-out", "site")
# cada programa: a pasta do build.zig e o nome dos arquivos que o emcc gera em <pasta>/zig-out/web
PROGRAMS = (("aerodrive", "aerodrive"), ("aerosim", "aerosim"), ("aeroopt", "aeroopt"))
EXTENSIONS = (".html", ".js", ".wasm", ".data")


def web_folder(folder: str) -> str:
    return os.path.join(ROOT, folder, "zig-out", "web")


def build(folder: str) -> None:
    """Compila um programa para wasm32-emscripten (saída em <pasta>/zig-out/web). O aerosim e o aeroopt saem em
    ReleaseSafe, como no PC (em Debug a análise da asa fica lenta demais)."""
    command = [sys.executable, "-m", "ziglang", "build", "-Dtarget=wasm32-emscripten"]
    if folder != "aerodrive":
        command.append("--release=safe")
    print(f"compilando o {folder} para o navegador:", " ".join(command[2:]))
    subprocess.run(command, cwd=os.path.join(ROOT, folder), check=True)


def assemble() -> None:
    """Copia a tela inicial e os arquivos dos programas para zig-out/site (apaga a montagem anterior)."""
    missing = [
        os.path.relpath(os.path.join(web_folder(folder), name + extension), ROOT)
        for folder, name in PROGRAMS
        for extension in EXTENSIONS
        if not os.path.isfile(os.path.join(web_folder(folder), name + extension))
    ]
    if missing:
        sys.exit(f"faltam: {', '.join(missing)} (rode sem --sem-compilar)")
    shutil.rmtree(SITE, ignore_errors=True)
    os.makedirs(SITE)
    shutil.copy2(LAUNCHER, os.path.join(SITE, "index.html"))
    for folder, name in PROGRAMS:
        for extension in EXTENSIONS:
            shutil.copy2(os.path.join(web_folder(folder), name + extension), os.path.join(SITE, name + extension))
    # o GitHub Pages não passa a pasta pelo Jekyll (que esconderia arquivos e atrasaria a publicação)
    open(os.path.join(SITE, ".nojekyll"), "w").close()
    total = sum(os.path.getsize(os.path.join(SITE, name)) for name in os.listdir(SITE))
    print(f"site montado em {os.path.relpath(SITE, ROOT)} ({total / 2**20:.1f} MiB):")
    for name in sorted(os.listdir(SITE)):
        print(f"  {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sem-compilar", action="store_true", help="usa os programas já compilados")
    options = parser.parse_args()
    if not options.sem_compilar:
        for folder, _ in PROGRAMS:
            build(folder)
    assemble()


if __name__ == "__main__":
    main()
