"""Monta o programa instalável: a tela inicial (o menu do site), o aerosim, o aeroopt e o AeroDrive numa pasta só,
com os aviões de exemplo e os perfis, e daí o AppImage (Linux) ou o instalador .exe (Windows).

    python tools/package.py                      # Linux: dist/AircraftSimulation-linux/ e, com o appimagetool, o .AppImage
    python tools/package.py --alvo windows       # Windows (compilado daqui): dist/AircraftSimulation-windows/ e, com o
                                                 # makensis (NSIS), o instalador .exe
    python tools/package.py --sem-compilar       # só monta, com o que já está em <pasta>/zig-out/bin

A pasta montada já roda sozinha: abrir `aircraftsimulation` (ou `aircraftsimulation.exe`). Os programas acham os
dados (`data/aircraft`, `data/airfoils`) ao lado deles. A página do site (`web/index.html`) e a documentação
(`zig build site`: o livro, o mapa do código e o tracking) vão junto em `site/`.
O appimagetool vem de https://github.com/AppImage/appimagetool (variável APPIMAGETOOL ou no PATH); o makensis, do
pacote `nsis` (apt) ou de https://nsis.sourceforge.io. Sem eles, fica só a pasta (e um .zip dela no Windows).
O GitHub Actions (.github/workflows/pacotes.yml) roda este script quando alguém pede, sem chave nenhuma.

Os métodos de fora do núcleo (lltdrek, AeroSandbox, AVL) são bibliotecas em Python, chamadas pelo adaptador
`aerosim/bridge.py`. Para eles, o pacote leva, na pasta `app/`, um Python portátil (`app/python`,
python-build-standalone, https://github.com/astral-sh/python-build-standalone) com o numpy e as bibliotecas que o pip
achar para o alvo (aerosandbox, lltdrek, optvl), mais o adaptador e uma cópia de `data/`. A tela do aerosim acha esse
Python sozinha (`aerosim/gui/python_bridge.zig`). `--sem-python` monta sem ele: tudo funciona, menos os métodos de fora.
"""
from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DIST = os.path.join(ROOT, "dist")
# a tela inicial primeiro: é ela que o pacote abre
PROGRAMS = (("launcher", "aircraftsimulation"), ("aerosim", "aerosim"), ("aeroopt", "aeroopt"), ("aerodrive", "aerodrive"))
DATA = ("aircraft", "airfoils")
TARGETS = {"linux": "x86_64-linux-gnu", "windows": "x86_64-windows-gnu"}
ICON = os.path.join(ROOT, "aerosim", "gui", "ui", "albatroz.png")
CACHE = os.path.join(DIST, "cache")
# o Python portátil: a versão e o nome do arquivo de cada alvo na release do python-build-standalone
PYTHON_VERSION, PYTHON_RELEASE = "3.12.7", "20241016"
PYTHON_FILES = {"linux": "x86_64-unknown-linux-gnu", "windows": "x86_64-pc-windows-msvc"}
PYTHON_NEEDED = ("numpy",)                            # o que o adaptador importa sempre
PYTHON_OPTIONAL = ("aerosandbox", "optvl", "git+https://github.com/kuodrek/lltdrek.git")   # requirements-aero.txt


def compile_programs(target: str) -> None:
    """Compila os quatro programas em ReleaseSafe para o alvo (cada um na pasta dele, em zig-out/<alvo>)."""
    for folder, _ in PROGRAMS:
        # no Linux, o alvo nativo (com -Dtarget o Zig não procura as bibliotecas do sistema, como a do OpenGL), mas
        # com a CPU de base, para o programa rodar em qualquer x86_64
        where = ["-Dcpu=baseline"] if target == "linux" else [f"-Dtarget={TARGETS[target]}"]
        command = [sys.executable, "-m", "ziglang", "build", "--release=safe", *where,
                   "--prefix", os.path.join("zig-out", target)]
        print(f"compilando {folder} ({target})")
        subprocess.run(command, cwd=os.path.join(ROOT, folder), check=True)


def assemble(target: str) -> str:
    """Copia os programas, os dados e a página do site para dist/AircraftSimulation-<alvo>; devolve a pasta."""
    suffix = ".exe" if target == "windows" else ""
    out = os.path.join(DIST, f"AircraftSimulation-{target}")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    for folder, name in PROGRAMS:
        built = os.path.join(ROOT, folder, "zig-out", target, "bin", name + suffix)
        if not os.path.isfile(built):
            sys.exit(f"falta {os.path.relpath(built, ROOT)} (rode sem --sem-compilar)")
        shutil.copy2(built, os.path.join(out, name + suffix))
    for part in DATA:  # só copia: nada dentro de data/ é gerado nem editado
        shutil.copytree(os.path.join(ROOT, "data", part), os.path.join(out, "data", part))
    os.makedirs(os.path.join(out, "site"))
    shutil.copy2(os.path.join(ROOT, "web", "index.html"), os.path.join(out, "site", "index.html"))
    web = os.path.join(ROOT, "aerodrive", "zig-out", "web")  # o AeroDrive do navegador, se já foi compilado
    for name in ("aerodrive.html", "aerodrive.js", "aerodrive.wasm", "aerodrive.data"):
        if os.path.isfile(os.path.join(web, name)):
            shutil.copy2(os.path.join(web, name), os.path.join(out, "site", name))
    # a documentação (livro, mapa do código e tracking), que a tela inicial abre no navegador
    subprocess.run([sys.executable, "-m", "ziglang", "build", "site", "--", "--saida", os.path.join(out, "site")], cwd=ROOT, check=True)
    print(f"pasta montada: {os.path.relpath(out, ROOT)}")
    return out


def portable_python(target: str) -> str:
    """O Python portátil do alvo, baixado uma vez para dist/cache; devolve o .tar.gz."""
    name = f"cpython-{PYTHON_VERSION}+{PYTHON_RELEASE}-{PYTHON_FILES[target]}-install_only.tar.gz"
    path = os.path.join(CACHE, name)
    if not os.path.isfile(path):
        os.makedirs(CACHE, exist_ok=True)
        url = f"https://github.com/astral-sh/python-build-standalone/releases/download/{PYTHON_RELEASE}/{name}"
        print("baixando", url)
        urllib.request.urlretrieve(url, path + ".parte")
        os.replace(path + ".parte", path)
    return path


def pip_install(target: str, out: str, packages: list[str]) -> bool:
    """Instala `packages` no Python do pacote (`out` é a pasta `app/`). No Linux, pelo próprio Python portátil; no Windows (compilado daqui),
    pelo pip de quem roda o script, só com wheels do Windows, direto no site-packages. Devolve se deu certo."""
    if target == "linux":
        command = [os.path.join(out, "python", "bin", "python3"), "-m", "pip", "install", "--no-warn-script-location"]
    else:
        short = "".join(PYTHON_VERSION.split(".")[:2])
        command = [sys.executable, "-m", "pip", "install", "--target", os.path.join(out, "python", "Lib", "site-packages"),
                   "--platform", "win_amd64", "--python-version", short, "--implementation", "cp",
                   "--only-binary=:all:", "--upgrade"]
    return subprocess.run(command + ["--disable-pip-version-check", "-q", *packages]).returncode == 0


def add_python(target: str, folder: str) -> None:
    """Põe no pacote, na pasta `app/`, o Python portátil com as bibliotecas, o adaptador (`aerosim/*.py`) e o
    `data/` inteiro (o catálogo de perfis). Fica numa pasta à parte porque no Linux o programa `aerosim` e a pasta
    `aerosim/` do Python teriam o mesmo nome."""
    out = os.path.join(folder, "app")
    os.makedirs(out)
    with tarfile.open(portable_python(target)) as archive:   # o arquivo traz a pasta python/
        archive.extractall(out, filter="tar")
    if not pip_install(target, out, list(PYTHON_NEEDED)):
        sys.exit("o pip não instalou " + ", ".join(PYTHON_NEEDED))
    for package in PYTHON_OPTIONAL:          # opcionais: sem eles, a Aerodinâmica usa só o núcleo
        if package.startswith("git+") and target == "windows":   # do git: a wheel pura primeiro, depois a instalação
            wheels = os.path.join(CACHE, "wheels")
            done = subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps", "-q", "-w", wheels, package])
            found = sorted(f for f in os.listdir(wheels) if f.endswith(".whl")) if done.returncode == 0 else []
            ok = bool(found) and pip_install(target, out, [os.path.join(wheels, f) for f in found])
        else:
            ok = pip_install(target, out, [package])
        print(("instalado: " if ok else "pulado (o pip não achou para este alvo): ") + package)
    tracked = subprocess.run(["git", "ls-files", "aerosim", "data"], cwd=ROOT, check=True, capture_output=True,
                             text=True).stdout.split()
    for name in tracked:   # como no site (tools/web_build.py): o adaptador e o data/ inteiro
        if name.startswith("data/") or name.endswith(".py") and not name.startswith("aerosim/gui/"):
            destination = os.path.join(out, name)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copy2(os.path.join(ROOT, name), destination)
    if sys.version_info[:2] == tuple(int(x) for x in PYTHON_VERSION.split(".")[:2]):   # .pyc prontos (o AppImage
        subprocess.run([sys.executable, "-m", "compileall", "-q", os.path.join(out, "aerosim")])   # é só leitura)
    print("Python do aerosim:", os.path.relpath(os.path.join(out, "python"), ROOT))


def appimage(folder: str) -> None:
    """O AppImage: a pasta vai em usr/lib/aircraftsimulation e o AppRun abre a tela inicial."""
    tool = os.environ.get("APPIMAGETOOL") or shutil.which("appimagetool")
    app_dir = os.path.join(DIST, "AircraftSimulation.AppDir")
    shutil.rmtree(app_dir, ignore_errors=True)
    shutil.copytree(folder, os.path.join(app_dir, "usr", "lib", "aircraftsimulation"))
    run = os.path.join(app_dir, "AppRun")
    with open(run, "w", encoding="utf-8") as fh:
        fh.write('#!/bin/sh\nexec "$APPDIR/usr/lib/aircraftsimulation/aircraftsimulation" "$@"\n')
    os.chmod(run, os.stat(run).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    with open(os.path.join(app_dir, "aircraftsimulation.desktop"), "w", encoding="utf-8") as fh:
        fh.write("[Desktop Entry]\nType=Application\nName=AircraftSimulation\n"
                 "Comment=Dimensionar uma aeronave e voar o resultado\nExec=aircraftsimulation\n"
                 "Icon=aircraftsimulation\nCategories=Science;Education;\nTerminal=false\n")
    shutil.copy2(ICON, os.path.join(app_dir, "aircraftsimulation.png"))
    if tool is None:
        print("sem o appimagetool: ficou só a pasta", os.path.relpath(app_dir, ROOT))
        return
    image = os.path.join(DIST, "AircraftSimulation-x86_64.AppImage")
    env = dict(os.environ, ARCH="x86_64")
    subprocess.run([tool, app_dir, image], check=True, env=env)
    print("AppImage:", os.path.relpath(image, ROOT))


NSIS = r"""; instalador do AircraftSimulation (gerado por tools/package.py)
Unicode true
Name "AircraftSimulation"
OutFile "{out_file}"
InstallDir "$PROGRAMFILES64\AircraftSimulation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "AircraftSimulation"
  SetShellVarContext all
  SetOutPath "$INSTDIR"
  File /r "{folder_glob}"
  WriteUninstaller "$INSTDIR\desinstalar.exe"
  ; aparece em "Adicionar ou remover programas"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "DisplayName" "AircraftSimulation"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "UninstallString" "$INSTDIR\desinstalar.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "DisplayIcon" "$INSTDIR\aircraftsimulation.exe"
  CreateDirectory "$SMPROGRAMS\AircraftSimulation"
  CreateShortcut "$SMPROGRAMS\AircraftSimulation\AircraftSimulation.lnk" "$INSTDIR\aircraftsimulation.exe" "" "" 0 SW_SHOWNORMAL "" "Dimensionar uma aeronave e voar o resultado"
  CreateShortcut "$SMPROGRAMS\AircraftSimulation\Desinstalar.lnk" "$INSTDIR\desinstalar.exe"
  CreateShortcut "$DESKTOP\AircraftSimulation.lnk" "$INSTDIR\aircraftsimulation.exe"
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation"
  RMDir /r "$SMPROGRAMS\AircraftSimulation"
  Delete "$DESKTOP\AircraftSimulation.lnk"
  RMDir /r "$INSTDIR"
SectionEnd
"""


def installer(folder: str) -> None:
    """O instalador .exe (NSIS), em Arquivos de Programas, com atalhos e desinstalador (sem assinatura: o Windows
    avisa na primeira vez); sem o makensis, um .zip da pasta."""
    tool = shutil.which("makensis")
    if tool is None:
        archive = shutil.make_archive(folder, "zip", os.path.dirname(folder), os.path.basename(folder))
        print("sem o makensis: ficou o zip", os.path.relpath(archive, ROOT))
        return
    out_file = os.path.join(DIST, "AircraftSimulation-instalador.exe")
    script = os.path.join(DIST, "instalador.nsi")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write(NSIS.format(out_file=out_file, folder_glob=os.path.join(folder, "*")))
    subprocess.run([tool, "-V2", script], check=True)
    print("instalador:", os.path.relpath(out_file, ROOT))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--alvo", choices=sorted(TARGETS), default="windows" if os.name == "nt" else "linux")
    parser.add_argument("--sem-compilar", action="store_true", help="usa o que já está em <pasta>/zig-out/<alvo>")
    parser.add_argument("--sem-python", action="store_true", help="sem o Python do aerosim (abre só a Montagem)")
    options = parser.parse_args()
    if not options.sem_compilar:
        compile_programs(options.alvo)
    folder = assemble(options.alvo)
    if not options.sem_python:
        add_python(options.alvo, folder)
    if options.alvo == "linux":
        appimage(folder)
    else:
        installer(folder)


if __name__ == "__main__":
    main()
