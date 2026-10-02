"""Planilhas "por endereço de célula" (ex.: Dados_Desempenho.xlsx) e catálogos por cabeçalho
(ex.: Propellers&Motors.xlsx).

Em vez de código com `sheet["C4"].value` espalhado, um ARQUIVO DE MAPA (.json) diz qual
campo do modelo vem de qual célula, com escala. Trocar a planilha = trocar o mapa.

    {
      "base": "conventional",                       # aeronave de partida (template ou arquivo)
      "fields": {
        "mass.base_mass": "Geral!C8",
        "surfaces[wing].CLa": {"cell": "Superficies!C4", "scale": 57.29577951308232,
                               "note": "planilha em 1/grau"},
        "@wing.area": "Superficies!C3",              # geometria derivada (refaz as seções)
        ...
      }
    }

Caminhos: `a.b.c`, listas por índice `propulsion[0]` ou por papel `surfaces[wing]`,
vetores `mass.base_cg[0]`. Chaves com `@papel.` ajustam a geometria da superfície:
area, span, xac (centro aerodinâmico), chord, K (fator de arrasto induzido -> Oswald).
"set": {"tanks": [], ...} aplica valores constantes antes de ler as células.
"""
from __future__ import annotations

import json
import math
import os
import re

from aerosim.interfaces.aircraft_source import IAircraftSource, ICatalogSource
from aerosim.model.aircraft import Aircraft, LiftingSurface, WingSection
from aerosim.model.catalog import Battery, Catalog, Motor, Propeller

_TOK = re.compile(r"([A-Za-z_][A-Za-z_0-9]*)(?:\[([^\]]+)\])?")


def _split_cell(ref: str) -> tuple[str, str]:
    sheet, _, cell = ref.rpartition("!")
    return sheet, cell


def _resolve(root, path: str):
    """devolve (objeto pai, atributo ou índice) do caminho"""
    toks = path.split(".")
    obj = root
    for i, t in enumerate(toks):
        m = _TOK.fullmatch(t)
        if not m:
            raise KeyError(f"caminho inválido: {path}")
        name, sel = m.group(1), m.group(2)
        last = i == len(toks) - 1
        if sel is None:
            if last:
                return obj, name
            obj = getattr(obj, name)
            continue
        seq = getattr(obj, name)
        if sel.lstrip("-").isdigit():
            idx = int(sel)
        else:
            idx = next((k for k, it in enumerate(seq) if getattr(it, "role", None) == sel or getattr(it, "name", None) == sel), None)
            if idx is None:
                raise KeyError(f"{path}: nenhum item '{sel}' em {name}")
        if last:
            return seq, idx
        obj = seq[idx]
    raise KeyError(path)


def _set(root, path, value):
    parent, key = _resolve(root, path)
    if isinstance(parent, list):
        parent[key] = value
    else:
        cur = getattr(parent, key)
        if isinstance(cur, bool):
            value = bool(value)
        elif isinstance(cur, int) and not isinstance(cur, bool):
            value = int(value)
        setattr(parent, key, value)


def _get(root, path):
    parent, key = _resolve(root, path)
    return parent[key] if isinstance(parent, list) else getattr(parent, key)


def _surface(ac: Aircraft, role: str) -> LiftingSurface:
    s = next((s for s in ac.surfaces if s.role == role or s.name == role), None)
    if s is None:
        raise KeyError(f"superfície '{role}' não existe na aeronave base")
    return s


def _reshape(s: LiftingSurface, area: float | None = None, span: float | None = None, chord: float | None = None):
    """refaz as seções mantendo afilamento, enflechamento e torção"""
    ss = sorted(s.sections, key=lambda q: q.y)
    root, tip = ss[0], ss[-1]
    taper = tip.chord / root.chord if root.chord > 0 else 1.0
    mult = 1 if (s.vertical or not s.symmetric) else 2
    b = span if span is not None else s.span
    semi = b / mult
    if area is not None:
        cmean = area / b
    elif chord is not None:
        cmean = chord * (1 + taper) / 2
    else:
        cmean = s.area / b if b > 0 else root.chord
    c_root = 2 * cmean / (1 + taper)
    sweep_per_y = (tip.x_offset - root.x_offset) / tip.y if tip.y > 0 else 0.0
    s.sections = [WingSection(f * semi, c_root * (1 + (taper - 1) * f), f * semi * sweep_per_y,
                              root.twist + (tip.twist - root.twist) * f) for f in (0.0, 1.0)]


class CellMapAircraftSource(IAircraftSource):
    extensions = (".xlsx",)

    def __init__(self, mapping: str | dict, base: Aircraft | None = None):
        if isinstance(mapping, str):
            with open(mapping, encoding="utf-8") as f:
                mapping = json.load(f)
        self.mapping = mapping
        self.base = base
        self.warnings: list[str] = []

    def _base(self) -> Aircraft:
        if self.base is not None:
            return self.base.copy()
        b = self.mapping.get("base", "conventional")
        from aerosim.model.templates import TEMPLATES
        if b in TEMPLATES:
            return TEMPLATES[b]()
        from .sources import load_aircraft
        return load_aircraft(b)

    @staticmethod
    def _spec(v) -> dict:
        return {"cell": v} if isinstance(v, str) else dict(v)

    def load(self, path: str) -> Aircraft:
        from openpyxl import load_workbook
        wb = load_workbook(path, data_only=True)
        ac = self._base()
        self.warnings = []
        geo: dict[str, dict] = {}
        for target, value in self.mapping.get("set", {}).items():      # constantes (ex.: tirar tanques)
            try:
                _set(ac, target, value)
            except (KeyError, IndexError, AttributeError) as e:
                self.warnings.append(f"set {target}: {e}")
        for target, raw in self.mapping.get("fields", {}).items():
            sp = self._spec(raw)
            sheet, cell = _split_cell(sp["cell"])
            if sheet not in wb.sheetnames:
                self.warnings.append(f"{target}: aba '{sheet}' não existe")
                continue
            v = wb[sheet][cell].value
            if v is None or isinstance(v, str) and not v.strip():
                self.warnings.append(f"{target}: {sp['cell']} vazia")
                continue
            if isinstance(v, (int, float)):
                v = float(v) * sp.get("scale", 1.0) + sp.get("offset", 0.0)
            try:
                if target.startswith("@"):
                    role, _, what = target[1:].partition(".")
                    geo.setdefault(role, {})[what] = v
                else:
                    _set(ac, target, v)
            except (KeyError, IndexError, AttributeError, TypeError, ValueError) as e:
                self.warnings.append(f"{target}: {e}")
        for role, g in geo.items():
            try:
                s = _surface(ac, role)
            except KeyError as e:
                self.warnings.append(str(e))
                continue
            if any(k in g for k in ("area", "span", "chord")):
                _reshape(s, g.get("area"), g.get("span"), g.get("chord"))
            if "xac" in g:
                s.x = g["xac"] + 0.25 * s.mac
            if "K" in g and g["K"] > 0:          # C_Di = K C_L²  ->  e = 1 / (π AR K)
                s.oswald = 1.0 / (math.pi * s.aspect_ratio * g["K"])
        wb.close()
        ac.apply_constraints()
        return ac

    def save(self, aircraft: Aircraft, path: str) -> None:
        """escreve os valores de volta nas mesmas células (abre a planilha se ela existir)"""
        from openpyxl import Workbook, load_workbook
        wb = load_workbook(path) if os.path.exists(path) else Workbook()
        for target, raw in self.mapping.get("fields", {}).items():
            sp = self._spec(raw)
            sheet, cell = _split_cell(sp["cell"])
            if sheet not in wb.sheetnames:
                wb.create_sheet(sheet)
            try:
                if target.startswith("@"):
                    role, _, what = target[1:].partition(".")
                    s = _surface(aircraft, role)
                    v = {"area": s.area, "span": s.span, "chord": s.mac, "xac": s.x - 0.25 * s.mac,
                         "K": 1.0 / (math.pi * s.aspect_ratio * s.oswald)}[what]
                else:
                    v = _get(aircraft, target)
            except (KeyError, IndexError, AttributeError):
                continue
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                v = (v - sp.get("offset", 0.0)) / sp.get("scale", 1.0)
            if v is None:
                continue
            wb[sheet][cell] = v
        if "Sheet" in wb.sheetnames and len(wb.sheetnames) > 1 and wb["Sheet"].max_row == 1:
            del wb["Sheet"]
        wb.save(path)


# ================================================================== catálogo por cabeçalhos
ALIASES = {
    "motors": {"name": ("name", "nome", "motor", "modelo", "model"), "Kv": ("kv", "kv (rpm/v)", "kv_rpm_v"),
               "Rm": ("rm", "r", "resistencia", "resistência", "rm (ohm)", "r (ohm)"),
               "Imax": ("imax", "i_max", "corrente max", "corrente máxima", "imax (a)"),
               "mass": ("mass", "massa", "peso", "massa (kg)"), "B": ("b",), "tauc": ("tauc", "torque_atrito"),
               "Jm": ("jm",)},
    "propellers": {"name": ("name", "nome", "helice", "hélice", "propeller", "modelo"),
                   "D": ("d", "diametro", "diâmetro", "d (m)"), "pitch": ("pitch", "passo"),
                   "Ip": ("ip",), "mass": ("mass", "massa")},
    "batteries": {"name": ("name", "nome", "bateria"), "cells": ("cells", "celulas", "células", "s"),
                  "Rint": ("rint", "r_int", "resistencia"), "capacity_mAh": ("capacity_mah", "capacidade", "mah"),
                  "mass": ("mass", "massa"), "V_cell": ("v_cell", "v_celula")},
}
CLASSES = {"motors": Motor, "propellers": Propeller, "batteries": Battery}


class TableCatalogSource(ICatalogSource):
    """Lê abas em forma de tabela (uma linha por item) com nomes de coluna livres.

        layout = {"motors": {"sheet": "Motores_Data", "header_row": 1},
                  "propellers": {"sheet": "Propellers_coefficients", "header_row": 2},
                  "prop_table": {"sheet": "...", "header_row": 1}}     # opcional: helice, J, CT, CP

    As colunas são reconhecidas por apelidos (ALIASES) ou por "columns": {"Kv": "KV [rpm/V]"}.
    Colunas sem correspondência ficam em `warnings` (ex.: coeficientes polinomiais p00..p05 de
    tração, que o núcleo não usa: ele precisa da tabela J, C_T, C_P).
    """
    extensions = (".xlsx",)

    def __init__(self, layout: dict | str):
        if isinstance(layout, str):
            with open(layout, encoding="utf-8") as f:
                layout = json.load(f)
        self.layout = layout
        self.warnings: list[str] = []

    def _rows(self, wb, cfg):
        sh = wb[cfg["sheet"]]
        hr = int(cfg.get("header_row", 1))
        head = [str(c.value).strip() if c.value is not None else "" for c in sh[hr]]
        return head, [dict(zip(head, r)) for r in sh.iter_rows(min_row=hr + 1, values_only=True)
                      if r and any(v is not None for v in r)]

    def load_catalog(self, path: str) -> Catalog:
        from openpyxl import load_workbook
        from aerosim.model.serialize import from_dict
        wb = load_workbook(path, data_only=True)
        cat = Catalog()
        self.warnings = []
        for kind in ("motors", "propellers", "batteries"):
            cfg = self.layout.get(kind)
            if not cfg or cfg["sheet"] not in wb.sheetnames:
                continue
            head, rows = self._rows(wb, cfg)
            colmap = {}
            for field, aliases in ALIASES[kind].items():
                explicit = cfg.get("columns", {}).get(field)
                hit = explicit if explicit in head else next((h for h in head if h.lower() in aliases), None)
                if hit:
                    colmap[field] = hit
            unused = [h for h in head if h and h not in colmap.values()]
            if unused:
                self.warnings.append(f"{cfg['sheet']}: colunas não usadas: {', '.join(unused)}")
            for i, r in enumerate(rows):
                d = {f: r[h] for f, h in colmap.items() if r.get(h) is not None}
                d.setdefault("name", f"{kind} {i + 1}")
                d["source"] = f"{os.path.basename(path)}:{cfg['sheet']}"
                getattr(cat, kind).append(from_dict(CLASSES[kind], d))
        pt = self.layout.get("prop_table")
        if pt and pt["sheet"] in wb.sheetnames:
            head, rows = self._rows(wb, pt)
            low = {h.lower(): h for h in head}
            pcol = low.get("helice") or low.get("hélice") or low.get("propeller") or low.get("name") or head[0]
            tab: dict[str, list] = {}
            for r in rows:
                tab.setdefault(str(r[pcol]), []).append((float(r[low["j"]]), float(r[low["ct"]]), float(r[low["cp"]])))
            for p in cat.propellers:
                pts = sorted(tab.get(p.name, []))
                if pts:
                    p.J, p.CT, p.CP = [a[0] for a in pts], [a[1] for a in pts], [a[2] for a in pts]
        for p in cat.propellers:
            if len(p.J) < 2:
                self.warnings.append(f"hélice '{p.name}' sem tabela J, C_T, C_P: o núcleo não consegue usá-la")
        wb.close()
        return cat

    def save_catalog(self, catalog: Catalog, path: str) -> None:
        from .sources import ExcelCatalogSource
        ExcelCatalogSource().save_catalog(catalog, path)

