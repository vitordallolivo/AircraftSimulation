"""O projeto da sprint numa pasta escolhida pelo usuário, com um arquivo por asa.

    <pasta>/sprint.json          requisitos, regras, perfis, rascunhos, estudos, mini-MDO, Montagem, tela
    <pasta>/<nome da asa>.json   a asa + as superfícies (empenagem e comandos) feitas para ela + os aviões

O nome da asa é o nome do arquivo: a asa é o projeto de sprint, e as superfícies são as opções dela
({asa, superficies: [s1, s2, ...], avioes: [...]}). Em memória continua o `DesignProject` de sempre;
aqui só se reparte e se junta.

Uma superfície guardada leva uma cópia da asa (é assim no `DesignProject`). Se a cópia for diferente da
asa guardada com o mesmo nome (a asa mudou depois), ela vai para outro arquivo, "<nome> (2).json", e
nada se perde. Do mesmo jeito, o avião que leva uma cópia antiga da superfície guarda essa cópia.

Arquivos de asa que outra pessoa copiar para a pasta entram no projeto ao abrir. Ao gravar, os arquivos
de asa desta pasta que o projeto não usa mais são apagados (só os que têm a marca de arquivo de asa).

O projeto antigo (um .json só, `DesignProject.save`) continua abrindo, e o arquivo dele não é alterado.

    p = load("~/sprint")       # pasta nova ou com sprint.json; pasta antiga com projeto.json; ou o .json antigo
    save(p, "~/sprint")
"""
from __future__ import annotations

import copy
import json
import os
import re

from aerosim.model.serialize import from_dict, to_dict

from .power import AircraftCandidate, PowerParams
from .project import DesignProject
from .tail import SetCandidate, TailParams
from .wing import WingCandidate

MAIN = "sprint.json"
LEGACY = "projeto.json"
KIND = "aerosim-sprint"
WING_KIND = "aerosim-sprint-asa"
VERSION = 2
SPLIT = ("wings", "sets", "aircraft")      # o que vai para os arquivos de asa


def _same(a, b) -> bool:
    return to_dict(a) == to_dict(b)


def file_name(name: str) -> str:
    """nome da asa → nome de arquivo (sem os caracteres que o Windows não aceita)"""
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name).strip().rstrip(".") or "asa"
    if s.lower() in (MAIN[:-5], LEGACY[:-5]):
        s += " (asa)"
    return s + ".json"


class _Group:
    def __init__(self, wing: WingCandidate, file: str):
        self.wing, self.file = wing, file
        self.kept = False                       # é uma das asas da etapa Asa (e não só a cópia de uma superfície)
        self.sets: list[SetCandidate] = []
        self.aircraft: list[AircraftCandidate] = []

    def set_named(self, name: str) -> SetCandidate | None:
        return next((s for s in self.sets if s.name == name), None)


def _groups(p: DesignProject) -> tuple[list[_Group], dict]:
    groups: list[_Group] = []
    order = dict(wings=[], sets=[], aircraft=[])

    def group_for(w: WingCandidate) -> _Group:
        for g in groups:
            if g.wing.name == w.name and _same(g.wing, w):
                return g
        taken = {g.file.lower() for g in groups}
        f, k = file_name(w.name), 2
        while f.lower() in taken:
            f, k = file_name(f"{w.name} ({k})"), k + 1
        groups.append(_Group(copy.deepcopy(w), f))
        return groups[-1]

    for w in p.wings:
        g = group_for(w)
        g.kept = True
        order["wings"].append(g.file)
    for s in p.sets:
        g = group_for(s.wing)
        g.sets.append(s)
        order["sets"].append([g.file, s.name])
    for a in p.aircraft:
        g = group_for(a.set.wing)
        g.aircraft.append(a)
        order["aircraft"].append([g.file, a.name])
    return groups, order


def split(p: DesignProject) -> tuple[dict, dict[str, dict]]:
    """o projeto → (sprint.json, {arquivo da asa: conteúdo})"""
    groups, order = _groups(p)
    main = {k: v for k, v in to_dict(p).items() if k not in SPLIT}
    main = dict(format=KIND, version=VERSION, order=order, **main)
    files = {}
    for g in groups:
        planes = []
        for a in g.aircraft:
            d = dict(params=to_dict(a.params), note=a.note, superficie=a.set.name)
            own = g.set_named(a.set.name)
            if own is None or not _same(own, a.set):         # cópia antiga da superfície: vai junto
                d["superficie_copia"] = dict(params=to_dict(a.set.params), note=a.set.note)
            planes.append(d)
        files[g.file] = dict(format=WING_KIND, version=VERSION, nome=g.wing.name, guardada=g.kept,
                             asa=to_dict(g.wing),
                             superficies=[dict(params=to_dict(s.params), note=s.note) for s in g.sets],
                             avioes=planes)
    return main, files


def _write(path: str, data: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def _read(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def wing_files(folder: str) -> dict[str, dict]:
    """os arquivos de asa da pasta (nome do arquivo → conteúdo)"""
    out = {}
    if not os.path.isdir(folder):
        return out
    for n in sorted(os.listdir(folder)):
        if n.lower().endswith(".json") and n not in (MAIN, LEGACY):
            d = _read(os.path.join(folder, n))
            if d is not None and d.get("format") == WING_KIND:
                out[n] = d
    return out


def save(p: DesignProject, folder: str) -> list[str]:
    """grava o projeto na pasta; devolve os arquivos escritos"""
    os.makedirs(folder, exist_ok=True)
    main, files = split(p)
    for n, d in files.items():
        _write(os.path.join(folder, n), d)
    for n in wing_files(folder):                     # asas que saíram do projeto
        if n not in files:
            os.remove(os.path.join(folder, n))
    _write(os.path.join(folder, MAIN), main)
    return [MAIN, *files]


def join(main: dict, files: dict[str, dict]) -> DesignProject:
    """(sprint.json, arquivos das asas) → o projeto"""
    base = {k: v for k, v in main.items() if k not in ("format", "version", "order", *SPLIT)}
    p = from_dict(DesignProject, base)
    wing = {n: from_dict(WingCandidate, d["asa"]) for n, d in files.items() if "asa" in d}
    sets: dict[str, list[SetCandidate]] = {}
    planes: dict[str, list[AircraftCandidate]] = {}
    for n, d in files.items():
        if n not in wing:
            continue
        sets[n] = [SetCandidate(from_dict(TailParams, s.get("params", {})), copy.deepcopy(wing[n]), s.get("note", ""))
                   for s in d.get("superficies", [])]
        planes[n] = []
        for a in d.get("avioes", []):
            cp = a.get("superficie_copia")
            if cp is not None:
                st = SetCandidate(from_dict(TailParams, cp.get("params", {})), copy.deepcopy(wing[n]), cp.get("note", ""))
            else:
                st = next((s for s in sets[n] if s.name == a.get("superficie")), None)
                st = copy.deepcopy(st) if st is not None else SetCandidate(TailParams(name=a.get("superficie", "")),
                                                                           copy.deepcopy(wing[n]))
            planes[n].append(AircraftCandidate(from_dict(PowerParams, a.get("params", {})), st, a.get("note", "")))

    order = main.get("order", {})
    used = set()

    def pick(kind: str, items: dict[str, list], name_of) -> list:
        out = []
        for ref in order.get(kind, []):
            f, nm = (ref, None) if isinstance(ref, str) else ref
            for i, x in enumerate(items.get(f, [])):
                if (f, kind, i) not in used and (nm is None or name_of(x) == nm):
                    used.add((f, kind, i))
                    out.append(x)
                    break
        for f in items:                       # arquivos copiados para a pasta (fora da ordem gravada)
            for i, x in enumerate(items[f]):
                if (f, kind, i) not in used:
                    used.add((f, kind, i))
                    out.append(x)
        return out

    kept = {n: [wing[n]] for n, d in files.items() if n in wing and d.get("guardada", True)}
    p.wings = pick("wings", kept, lambda w: w.name)
    p.sets = pick("sets", sets, lambda s: s.name)
    p.aircraft = pick("aircraft", planes, lambda a: a.name)
    return p


def is_folder(path: str) -> bool:
    """uma pasta de sprint (nova, com sprint.json; ou antiga, com projeto.json)"""
    return os.path.isdir(path) and (os.path.exists(os.path.join(path, MAIN)) or
                                    os.path.exists(os.path.join(path, LEGACY)))


def load(path: str) -> DesignProject:
    """abre a pasta (formato novo; senão o projeto.json antigo dela) ou um .json antigo"""
    if os.path.isdir(path):
        main = _read(os.path.join(path, MAIN))
        if main is not None:
            return join(main, wing_files(path))
        legacy = os.path.join(path, LEGACY)
        if os.path.exists(legacy):
            return DesignProject.load(legacy)
        files = wing_files(path)
        if files:                              # só arquivos de asa: um projeto novo com essas asas
            return join({}, files)
        return DesignProject()
    return DesignProject.load(path)


def is_sprint_path(path: str) -> bool:
    """pasta de sprint, projeto antigo (.json só) ou um arquivo de asa"""
    if os.path.isdir(path):
        return is_folder(path) or bool(wing_files(path))
    if not path.lower().endswith(".json"):
        return False
    d = _read(path)
    if d is not None and d.get("format") in (KIND, WING_KIND):
        return True
    from .project import is_project_file
    return is_project_file(path)


def folder_for(path: str) -> str:
    """onde o projeto aberto por `path` passa a ser gravado: a própria pasta; a pasta do sprint.json, do
    projeto.json ou do arquivo de asa; para outro .json antigo, uma pasta com o nome dele ao lado (o
    arquivo antigo fica como estava)"""
    if os.path.isdir(path):
        return path
    folder, name = os.path.split(os.path.abspath(path))
    d = _read(path) or {}
    if name in (MAIN, LEGACY) or d.get("format") == WING_KIND:
        return folder
    return os.path.join(folder, os.path.splitext(name)[0])


def open_path(path: str) -> tuple[DesignProject, str]:
    """(projeto, pasta onde ele vai ser gravado) para uma pasta, um .json antigo ou um arquivo de asa"""
    folder = folder_for(path)
    if os.path.isdir(path) or os.path.basename(path) == MAIN or (_read(path) or {}).get("format") == WING_KIND:
        return load(folder), folder
    return DesignProject.load(path), folder
