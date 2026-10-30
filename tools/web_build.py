"""Monta o site do AircraftSimulation em zig-out/site/: a tela inicial (web/index.html) e os três programas em
WebAssembly (AeroDrive, aerosim e aeroopt).

    python tools/web_build.py                 # compila os três para o navegador e monta o site
    python tools/web_build.py --sem-compilar  # só monta, com o que já está em <programa>/zig-out/web
    python tools/web_build.py --sem-python    # sem o Python do aerosim (a página abre só a Montagem)
    python -m http.server -d zig-out/site 8000   # e abrir http://localhost:8000

O aerosim pede as contas aos managers em Python, e no navegador quem roda o Python é o Pyodide. Por isso o site leva
também, para o aerosim: o Pyodide com o numpy e o scipy (pasta pyodide/), o pacote aerosim sem a GUI PyQt mais a
pasta data (aerosim-python.zip), o núcleo como side module do emscripten (aerosim-core.so, que o mesmo `ctypes` do PC
carrega) e a página que carrega tudo isso num iframe (aerosim-python.html). O Pyodide sai do release dele no GitHub e o side module é
ligado pelo emsdk da mesma versão do emscripten do Pyodide; os dois são baixados uma vez para zig-out/cache-web (ou
`--pyodide <pasta>` e `--emsdk <pasta>` com o que já se tem).

Os caminhos dentro do site são relativos (index.html -> aerodrive.html -> aerodrive.js/.wasm/.data; o mesmo para o
aerosim e o aeroopt), então a mesma
pasta serve na raiz de um servidor ou numa subpasta, como https://<usuario>.github.io/AircraftSimulation/.
O GitHub Actions (.github/workflows/site.yml) roda este script e publica a pasta no GitHub Pages.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
LAUNCHER = os.path.join(ROOT, "web", "index.html")
SITE = os.path.join(ROOT, "zig-out", "site")
# cada programa: a pasta do build.zig e o nome dos arquivos que o emcc gera em <pasta>/zig-out/web
PROGRAMS = (("aerodrive", "aerodrive"), ("aerosim", "aerosim"), ("aeroopt", "aeroopt"))
EXTENSIONS = (".html", ".js", ".wasm", ".data")

# o Python do aerosim no navegador
PYODIDE_VERSION = "314.0.7"
PYODIDE_URL = f"https://github.com/pyodide/pyodide/releases/download/{PYODIDE_VERSION}/pyodide-{PYODIDE_VERSION}.tar.bz2"
PYODIDE_FILES = ("pyodide.mjs", "pyodide.asm.mjs", "pyodide.asm.wasm", "python_stdlib.zip", "pyodide-lock.json")
PYODIDE_PACKAGES = ("numpy", "scipy")      # os que o aerosim importa sem os opcionais (lltdrek, ASB, AVL)
EMSCRIPTEN_VERSION = "5.0.3"               # a do Pyodide acima (pyodide-lock.json -> info.platform)
CACHE = os.path.join(ROOT, "zig-out", "cache-web")


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


def report() -> None:
    total = sum(os.path.getsize(os.path.join(folder, name)) for folder, _, names in os.walk(SITE) for name in names)
    print(f"site montado em {os.path.relpath(SITE, ROOT)} ({total / 2**20:.1f} MiB):")
    for name in sorted(os.listdir(SITE)):
        print(f"  {name}")


# ---------------------------------------------------------------------- o Python do aerosim


def pyodide_folder(given: str | None) -> str:
    """a pasta do Pyodide (a `pyodide/` do release): a dada, ou baixada uma vez para o cache só com o que o site usa"""
    if given:
        return given
    folder = os.path.join(CACHE, f"pyodide-{PYODIDE_VERSION}")
    if os.path.isfile(os.path.join(folder, "pyodide-lock.json")):
        return folder
    os.makedirs(CACHE, exist_ok=True)
    archive = os.path.join(CACHE, f"pyodide-{PYODIDE_VERSION}.tar.bz2")
    if not os.path.isfile(archive):
        print("baixando o Pyodide:", PYODIDE_URL)
        urllib.request.urlretrieve(PYODIDE_URL, archive + ".parte")
        os.replace(archive + ".parte", archive)
    print("extraindo o Pyodide (só o núcleo e as rodas do numpy e do scipy)")
    wanted = set(PYODIDE_FILES)
    with tarfile.open(archive) as tar:
        for member in tar:
            name = os.path.basename(member.name)
            if member.isfile() and (name in wanted or name.endswith(".whl") and name.split("-")[0] in PYODIDE_PACKAGES):
                member.name = name
                tar.extract(member, folder, filter="data")
    os.remove(archive)
    return folder


def emsdk_folder(given: str | None) -> str:
    """o emsdk com o emscripten do Pyodide: o dado, ou clonado e instalado uma vez no cache"""
    folder = given or os.path.join(CACHE, "emsdk")
    if not os.path.isdir(folder):
        subprocess.run(["git", "clone", "-q", "https://github.com/emscripten-core/emsdk", folder], check=True)
    if not os.path.isfile(os.path.join(folder, "upstream", "emscripten", "emcc")):
        for step in ("install", "activate"):
            subprocess.run([os.path.join(folder, "emsdk"), step, EMSCRIPTEN_VERSION], cwd=folder, check=True)
    return folder


def build_core(emsdk: str) -> str:
    """o núcleo para o Pyodide: a biblioteca estática do Zig (wasm32-emscripten, relocável) ligada pelo emcc como
    side module. Devolve o caminho do .so"""
    core = os.path.join(ROOT, "core")
    prefix = os.path.join(core, "zig-out", "web")
    subprocess.run([sys.executable, "-m", "ziglang", "build", "-Dtarget=wasm32-emscripten", "--release=fast",
                    "--prefix", prefix], cwd=core, check=True)
    output = os.path.join(prefix, "aerosim-core.so")
    link = (f'source "{os.path.join(emsdk, "emsdk_env.sh")}" >/dev/null 2>&1 && emcc -O2 -sSIDE_MODULE=1 '
            f'-sWASM_BIGINT -Wl,--whole-archive "{os.path.join(prefix, "lib", "libaerosim.a")}" '
            f'-Wl,--no-whole-archive -o "{output}"')
    print("ligando o núcleo como side module (emcc", EMSCRIPTEN_VERSION + ")")
    subprocess.run(["bash", "-c", link], check=True)
    return output


def python_archive(target: str) -> None:
    """o pacote aerosim (sem a GUI, que é PyQt) e a pasta data, como estão no git, num zip para o Pyodide abrir"""
    tracked = subprocess.run(["git", "ls-files", "aerosim", "data"], cwd=ROOT, check=True, capture_output=True,
                             text=True).stdout.split()
    files = [name for name in tracked if name.startswith("data/")
             or name.endswith(".py") and not name.startswith("aerosim/gui/")]
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(os.path.join(ROOT, name), name)


def add_python(pyodide: str, core: str) -> None:
    """põe no site o que o aerosim precisa para pedir as contas ao Python (ver o começo deste arquivo)"""
    lock = json.load(open(os.path.join(pyodide, "pyodide-lock.json"), encoding="utf-8"))
    platform = lock["info"]["platform"]
    if platform != "emscripten_" + EMSCRIPTEN_VERSION.replace(".", "_"):
        sys.exit(f"o Pyodide é de {platform}, e o núcleo é ligado com o emscripten {EMSCRIPTEN_VERSION}")
    target = os.path.join(SITE, "pyodide")
    os.makedirs(target)
    names = list(PYODIDE_FILES)
    pending = list(PYODIDE_PACKAGES)
    while pending:                                  # os pacotes e as dependências deles
        package = lock["packages"][pending.pop()]
        if package["file_name"] not in names:
            names.append(package["file_name"])
            pending.extend(package["depends"])
    for name in names:
        shutil.copy2(os.path.join(pyodide, name), os.path.join(target, name))
    shutil.copy2(core, os.path.join(SITE, "aerosim-core.so"))
    python_archive(os.path.join(SITE, "aerosim-python.zip"))
    shutil.copy2(os.path.join(ROOT, "aerosim", "gui", "web", "python.html"), os.path.join(SITE, "aerosim-python.html"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sem-compilar", action="store_true", help="usa os programas já compilados")
    parser.add_argument("--sem-python", action="store_true", help="sem o Python do aerosim (só a Montagem)")
    parser.add_argument("--pyodide", help="pasta do Pyodide já extraída (a pyodide/ do release)")
    parser.add_argument("--emsdk", help=f"pasta de um emsdk com o emscripten {EMSCRIPTEN_VERSION} instalado")
    options = parser.parse_args()
    if not options.sem_compilar:
        for folder, _ in PROGRAMS:
            build(folder)
    core = None if options.sem_python else build_core(emsdk_folder(options.emsdk))
    assemble()
    if core:
        add_python(pyodide_folder(options.pyodide), core)
    report()


if __name__ == "__main__":
    main()
