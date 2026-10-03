"""IProjectStore em JSON: uma pasta, um arquivo por aeronave (<nome>.json).

O arquivo é autossuficiente (perfis com as coordenadas dentro) e também abre por
Arquivo → Abrir, como qualquer .json de aeronave:
    {"formato": "aerosim-aeronave", "versao": 1, "nome": ..., "salvo_em": ..., "resumo": ...,
     "aeronave": {...}}
Pasta padrão: variável de ambiente AEROSIM_PROJETOS, senão ~/aerosim_aeronaves.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import unicodedata

from aerosim.interfaces.project_store import IProjectStore, ProjectInfo
from aerosim.model.aircraft import Aircraft
from aerosim.model.serialize import from_dict, to_dict

FORMAT = "aerosim-aeronave"


def default_root() -> str:
    return os.environ.get("AEROSIM_PROJETOS") or os.path.join(os.path.expanduser("~"), "aerosim_aeronaves")


def slug(name: str) -> str:
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("._")
    return s or "aeronave"


def summary(ac: Aircraft) -> str:
    from aerosim.model.features import features
    from aerosim.model.massprops import dry_mass
    S, c, b = ac.references()
    try:
        m = dry_mass(ac)["m"]
    except Exception:
        m = float("nan")
    return f"S = {S:.3f} m², b = {b:.2f} m, massa seca {m:.2f} kg; {features(ac).summary()}"


class JsonProjectStore(IProjectStore):
    def __init__(self, root: str | None = None):
        self.root = root or default_root()

    def _path(self, name: str) -> str:
        return os.path.join(self.root, slug(name) + ".json")

    def list(self) -> list[ProjectInfo]:
        if not os.path.isdir(self.root):
            return []
        out = []
        for fn in sorted(os.listdir(self.root)):
            if not fn.endswith(".json"):
                continue
            p = os.path.join(self.root, fn)
            try:
                with open(p, encoding="utf-8") as f:
                    d = json.load(f)
            except (OSError, json.JSONDecodeError):
                continue
            if d.get("formato") != FORMAT:
                continue
            out.append(ProjectInfo(d.get("nome", fn[:-5]), p, d.get("salvo_em", ""), d.get("resumo", "")))
        return sorted(out, key=lambda i: i.saved, reverse=True)

    def exists(self, name: str) -> bool:
        return os.path.exists(self._path(name))

    def save(self, aircraft: Aircraft, name: str | None = None) -> ProjectInfo:
        name = (name or aircraft.name or "aeronave").strip()
        aircraft.name = name
        for s in aircraft.surfaces:          # perfis dentro do arquivo: abre em outra máquina
            s.airfoil.outline()
        os.makedirs(self.root, exist_ok=True)
        now = dt.datetime.now().isoformat(timespec="seconds")
        info = ProjectInfo(name, self._path(name), now, summary(aircraft))
        doc = {"formato": FORMAT, "versao": 1, "nome": name, "salvo_em": now, "resumo": info.summary,
               "aeronave": to_dict(aircraft)}
        tmp = info.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1, ensure_ascii=False)
        os.replace(tmp, info.path)
        return info

    def load(self, name: str) -> Aircraft:
        p = name if os.path.exists(name) else self._path(name)
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return from_dict(Aircraft, d["aeronave"] if d.get("formato") == FORMAT else d)

    def delete(self, name: str) -> None:
        p = self._path(name)
        if os.path.exists(p):
            os.remove(p)
