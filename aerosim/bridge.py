"""Ponte entre a tela em Zig (raylib) e os managers em Python: uma mensagem JSON por linha, na entrada e na saída
padrão. A tela abre `python -m aerosim.bridge` e pede; aqui se chama o Simulation Manager (que chama o núcleo) e as
etapas da sprint (`aerosim/manager/stages.py`), e se devolve o resultado já pronto para desenhar. Nada de conta
aqui: só se traduz o pedido, o `SimResult` e o rascunho das etapas.

Pedidos (cada um com um `id`, que volta na resposta; cada um roda na sua thread, e as respostas podem chegar fora
de ordem):
  {"op": "layout"}                                      as abas como na GUI PyQt: áreas, subabas, de que tipo
  {"op": "open", "path": "avião.json"}                 abre o avião (sem pedido: o avião vazio)
  {"op": "specs", "name": "wings", "values": {...}}     campos (`ParamSpec`) e gráficos (`PlotSpec`) da análise
  {"op": "run", "name": "wings", "values": {...}}       roda; antes da resposta vêm linhas {"id", "progress", "message"}
  {"op": "cancel", "target": id}                        para a rodada `target` (sem resposta)
  {"op": "stage", "name": "asa", "do": "show"}          uma etapa da sprint: o rascunho, os guardados, os botões e a
                                                        conta. `do` também pode ser "set" (com "values"), "keep",
                                                        "load" e "delete" (com "index") e "act" (com "key" e "arg")

Resposta: {"id", "ok": true, ...} ou {"id", "ok": false, "error": "texto"}. Os gráficos vêm com as curvas já
resolvidas (a tabela de cada `series:<prefixo>*` vira uma curva com nome, x e y), como a GUI PyQt faz em
`aerosim/gui/widgets/plots.py`.

O que as bibliotecas imprimem na saída padrão (inclusive o C) vai para a saída de erro: a saída padrão é só da ponte.

No navegador não há processo nem thread: o Pyodide roda este módulo na própria página, a página chama
`start_in_browser` uma vez e depois `call_in_browser` com cada pedido, que responde na hora com a linha da resposta
(sem as de progresso). A página faz isso em `aerosim/gui/web/python.html`.
"""
from __future__ import annotations

import json
import math
import os
import sys
import threading
import traceback
from dataclasses import asdict
from typing import Any

from aerosim.interfaces.simulation import AREAS, CancelledError, ISimulationManager, PlotSpec, SimResult

FORM_KINDS = ("float", "int", "bool", "choice", "str", "file", "floats")   # os tipos de campo que a tela em Zig desenha por enquanto
PLOT_KINDS = ("2d", "loads3d")                            # os tipos de gráfico idem (3d: só na GUI PyQt)

# a arrumação das abas, a mesma de `aerosim/gui/main_window.py` e `aerosim/gui/design/__init__.py`
INSIDE = {"propulsao": "desempenho", "missao": "desempenho"}
LAST_TAB = {"dimensionamento": "Diagrama de restrições", "aerodinamica": "Analisar"}
AREA_TAB = {"aerodinamica": "Aerodinâmica"}
TODO = {"dimensionamento": ("Mini-MDO (otimizador)",), "desempenho": ("Estudo e ponto de projeto",)}   # ainda sem ponte


class Bridge:
    def __init__(self, manager: ISimulationManager, out, design_dir: str | None = None):
        self.manager = manager
        self.out = out
        self.write_lock = threading.Lock()
        self.design_lock = threading.Lock()       # as etapas mexem no mesmo projeto: uma de cada vez
        self.runs: dict[Any, threading.Event] = {}
        from aerosim.model.aircraft import Aircraft
        self.aircraft = Aircraft()
        self.stages = self._stages(design_dir)

    def _stages(self, design_dir):
        from aerosim.data.projects import JsonProjectStore, default_root
        from aerosim.design import store
        from aerosim.design.project import DesignProject
        from aerosim.manager import stages
        root = default_root()
        folder = design_dir or os.path.join(root, "sprint")
        design = DesignProject()
        if os.path.isdir(folder):
            try:
                design = store.load(folder)
            except Exception:
                traceback.print_exc(file=sys.stderr)
        if isinstance(getattr(self.manager, "shared", None), dict):
            self.manager.shared["sprint"] = design            # a aba Asas lê as asas guardadas daqui
        ctx = stages.Context(design=design, catalog=_catalog(), backend=self.manager.backend,
                             projects=JsonProjectStore(root), folder=folder)
        return {name: cls(ctx) for name, cls in stages.STAGES.items()}

    # ------------------------------------------------------------------ saída
    def send(self, message: dict) -> None:
        line = json.dumps(_finite(message), ensure_ascii=False, default=_plain, allow_nan=False)
        with self.write_lock:
            self.out.write(line + "\n")
            self.out.flush()

    def reply(self, request: dict, **fields) -> None:
        self.send({"id": request.get("id"), "ok": True, **fields})

    def fail(self, request: dict, error: str) -> None:
        self.send({"id": request.get("id"), "ok": False, "error": error})

    # ------------------------------------------------------------------ pedidos
    def handle(self, request: dict) -> None:
        """cada pedido na sua thread (uma conta longa não segura os outros); o cancelamento vale na hora"""
        if request.get("op") == "cancel":
            event = self.runs.get(request.get("target"))
            if event is not None:
                event.set()
            return
        threading.Thread(target=self.answer, args=(request,), daemon=True).start()

    def answer(self, request: dict) -> None:
        op = request.get("op")
        try:
            if op == "layout":
                self.reply(request, areas=self.layout())
            elif op == "open":
                from aerosim.data.projects import load_file
                self.aircraft = load_file(request["path"])
                self.reply(request, name=getattr(self.aircraft, "name", "") or os.path.basename(request["path"]))
            elif op == "specs":
                sim = self.manager.get(request["name"])
                values = request.get("values") or {}
                self.reply(request, params=[_param(p) for p in sim.parameters_for(self.aircraft, values)],
                           plots=[_plot_spec(p) for p in sim.plots_for(self.aircraft, values)],
                           description=sim.description)
            elif op == "run":
                self.run(request)
            elif op == "stage":
                with self.design_lock:
                    self.reply(request, **self.stage(request))
            else:
                self.fail(request, f"pedido desconhecido: {op!r}")
        except CancelledError:
            self.fail(request, "cancelado")
        except Exception as error:     # a tela mostra o erro; a ponte segue viva
            traceback.print_exc(file=sys.stderr)
            self.fail(request, f"{type(error).__name__}: {error}")

    def layout(self) -> list[dict]:
        """as áreas e as subabas na ordem da GUI PyQt (`MainWindow.__init__`)"""
        from aerosim.manager.stages import PLACES
        sims = sorted(self.manager.simulations(), key=lambda s: AREAS.index(s.area) if s.area in AREAS else len(AREAS))
        areas: list[dict] = []
        by_area: dict[str, dict] = {}
        later = []
        for sim in sims:
            if sim.area in INSIDE:
                later.append(sim)
                continue
            host = by_area.get(sim.area)
            if host is not None and not host["single"]:
                host["tabs"].append(_tab(sim.title, "sim", sim.name))
                continue
            places = PLACES.get(sim.area, ()) + tuple((t, "") for t in TODO.get(sim.area, ()))
            if not places:
                area = {"title": sim.title, "single": True, "tabs": [_tab(sim.title, "sim", sim.name)]}
                by_area.setdefault(sim.area, area)
                areas.append(area)
                continue
            tabs = [_tab(title, "stage" if name else "todo", name) for title, name in places]
            tabs.append(_tab(LAST_TAB.get(sim.area, "Avião montado"), "sim", sim.name))
            area = {"title": AREA_TAB.get(sim.area, sim.title), "single": False, "tabs": tabs}
            by_area.setdefault(sim.area, area)
            areas.append(area)
        for sim in later:
            host = by_area.get(INSIDE[sim.area])
            if host is not None and not host["single"]:
                host["tabs"].append(_tab(sim.title, "sim", sim.name))
            else:
                areas.append({"title": sim.title, "single": True, "tabs": [_tab(sim.title, "sim", sim.name)]})
        areas.append({"title": "Montagem", "single": True, "tabs": [_tab("Montagem", "assembly", "")]})
        return areas

    def run(self, request: dict) -> None:
        name = request["name"]
        values = request.get("values") or {}
        cancel = self.runs[request.get("id")] = threading.Event()
        progress = lambda fraction, message: self.send({"id": request.get("id"), "progress": float(fraction),
                                                        "message": str(message)})
        try:
            sim = self.manager.get(name)
            result = self.manager.run(name, self.aircraft, values, on_progress=progress, cancel=cancel)
            plots = [_plot(spec, result) for spec in sim.plots_for(self.aircraft, values)]
            self.reply(request, status=result.status, summary=result.summary,
                       checks=[asdict(check) for check in result.checks], plots=plots)
        finally:
            self.runs.pop(request.get("id"), None)

    def stage(self, request: dict) -> dict:
        """faz o pedido na etapa e devolve a página inteira: o formulário, os guardados, os botões e a conta"""
        stage = self.stages[request["name"]]
        do = request.get("do", "show")
        message = ""
        if do == "set":
            stage.set(request.get("values") or {})
        elif do == "keep":
            name = stage.do_keep()
            message = f"guardado: {name}" if name else ""
        elif do == "load":
            stage.load(int(request.get("index", -1)))
        elif do == "delete":
            stage.delete(int(request.get("index", -1)))
        elif do == "act":
            message = stage.act(request["key"], str(request.get("arg", "")))
        elif do == "grid":
            stage.edit_grid(request.get("grid", ""), request.get("edit", "set"), int(request.get("row", -1)),
                            request.get("key", ""), request.get("value"))
        opened = ""
        if message.startswith("open:"):            # "Mandar para a Montagem": a tela abre o arquivo
            opened, message = message[5:].split("|", 1)
        disabled = set(stage.disabled())
        params = []
        for p in stage.form():
            item = _param(p)
            item["enabled"] = p.key.split(".")[-1].removesuffix("?auto") not in disabled
            params.append(item)
        outcome = stage.compute()
        page = {"title": stage.title, "help": stage.help, "keep_label": stage.keep_label, "params": params,
                "kept": stage.kept(), "actions": [asdict(a) for a in stage.actions()],
                "requirements": self.stages["requisitos"].ctx.design.requirements.summary(), "open": opened,
                "message": message, "grids": [asdict(g) for g in stage.grids()]}
        if outcome is not None:
            page.update(message=message or outcome.message, summary=outcome.result.summary,
                        checks=[asdict(c) for c in outcome.result.checks],
                        plots=[_plot(spec, outcome.result) for spec in outcome.plots],
                        tables=[asdict(t) for t in outcome.tables])
            if outcome.aircraft is not None:
                page["view"] = _view(outcome.aircraft, outcome.markers)
        return page


# ---------------------------------------------------------------------- tradução das specs e do resultado
def _tab(title: str, kind: str, name: str) -> dict:
    return {"title": title, "kind": kind, "name": name}


def _catalog():
    """o catálogo como a GUI PyQt monta (`AppState.__init__`): o embutido mais o de `data/catalog`"""
    from aerosim.model.catalog import builtin_catalog
    catalog = builtin_catalog()
    folder = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "catalog")
    if os.path.isdir(folder):
        from aerosim.data import load_catalog
        for name in ["catalog.cfg"] + sorted(x for x in os.listdir(folder) if x.endswith(".json")):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                try:
                    catalog = catalog.merge(load_catalog(path))
                except Exception:
                    pass
    return catalog


def _param(p) -> dict:
    return {"key": p.key, "label": p.label, "kind": p.kind if p.kind in FORM_KINDS else "unsupported",
            "default": p.default, "minimum": p.minimum, "maximum": p.maximum, "unit": p.unit,
            "choices": [str(c) for c in p.choices], "group": p.group, "help": p.help, "rebuild": p.rebuild,
            "enabled": True}


def _plot_spec(p: PlotSpec) -> dict:
    return {"key": p.key, "title": p.title, "xlabel": p.xlabel, "ylabel": p.ylabel,
            "kind": p.kind if p.kind in PLOT_KINDS else "unsupported"}


def _plot(spec: PlotSpec, result: SimResult) -> dict:
    """as curvas de um gráfico: uma por tabela e por coluna y (só as colunas que existem e são numéricas)"""
    out = _plot_spec(spec)
    out["curves"] = curves = []
    if out["kind"] == "loads3d":
        out["loads"] = _loads(spec, result)
        return out
    if out["kind"] != "2d":
        return out
    if spec.source == "log":
        tables = [("", result.log.columns)] if result.log is not None else []
    else:
        name = spec.source.split(":", 1)[1]
        if name.endswith("*"):
            tables = [(k[len(name) - 1:], v) for k, v in result.series.items() if k.startswith(name[:-1])]
        else:
            tables = [(name, result.series.get(name))]
    guides = []
    for label, table in tables:
        if isinstance(table, dict) and ("_vline" in table or "_hline" in table) and spec.x not in table:
            guides.append((label, table))                       # as retas de referência vão depois das curvas
            continue
        if not isinstance(table, dict) or spec.x not in table:
            continue
        for y in spec.ys:
            if y not in table:
                continue
            xs, ys = _numbers(table[spec.x]), _numbers(table[y])
            if xs is None or ys is None:
                continue
            if spec.swap:
                xs, ys = ys, xs
            title = str(table.get("_label") or label or y)
            if len(spec.ys) > 1:
                title = f"{title}: {y}"
            curves.append({"name": title, "x": xs, "y": ys, "dashed": table.get("_dash") is not None})
    _guides(curves, guides, spec.swap)
    return out


def _guides(curves: list, guides: list, swap: bool) -> None:
    """as retas de referência (`_vline` em x, `_hline` em y: cruzeiro, estol, fim do curso) como curvas de dois
    pontos que atravessam o que as curvas ocupam, com o nome na legenda (uma vez por nome)"""
    xs = [v for c in curves for v in c["x"] if v is not None]
    ys = [v for c in curves for v in c["y"] if v is not None]
    named = {c["name"] for c in curves}
    for label, table in guides:
        vertical = "_vline" in table
        value = _numbers([table["_vline" if vertical else "_hline"]])
        if value is None or value[0] is None:
            continue
        if swap:
            vertical = not vertical
        span = ys if vertical else xs
        low, high = (min(span), max(span)) if span else (value[0] - 1, value[0] + 1)
        x, y = ([value[0]] * 2, [low, high]) if vertical else ([low, high], [value[0]] * 2)
        name = str(table.get("_label") or label).strip()
        curves.append({"name": name, "x": x, "y": y, "dashed": table.get("_dash") is not None,
                       "legend": not table.get("_nolegend") and name not in named})
        named.add(name)


def _numbers(column) -> list | None:
    try:
        values = [float(v) for v in column]
    except (TypeError, ValueError):
        return None
    return [v if math.isfinite(v) else None for v in values]


def _finite(value: Any):
    """o JSON não tem NaN nem infinito: viram null (dentro de dicionários e listas também)"""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {k: _finite(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_finite(v) for v in value]
    if hasattr(value, "tolist") and not isinstance(value, (str, bytes)):
        return _finite(value.tolist())
    return value


def _mesh_list(meshes) -> list[dict]:
    """malhas (vértices, triângulos) com o tipo de cada uma, em listas planas com 5 casas (mm/100 basta para ver)"""
    import numpy as np
    out = []
    for (vertices, faces), kind in meshes:
        out.append({"kind": kind, "vertices": np.round(np.asarray(vertices, float), 5).ravel().tolist(),
                    "faces": np.asarray(faces, int).ravel().tolist()})
    return out


def _loads(spec: PlotSpec, result: SimResult) -> dict | None:
    """a vista 3D de uma análise de carga (a `LoadView` da GUI PyQt), só traduzida: a malha do método em
    triângulos (cada um com a face de origem), os campos por face com o rótulo e se têm sinal, as camadas de setas, o
    resto do avião (sem as superfícies, que o método já desenha) e o texto do caso"""
    import numpy as np
    from aerosim.interfaces.loads import CAMPOS, LoadResult, label
    table = result.series.get(spec.source.split(":", 1)[1]) or {}
    loads = table.get("_result")
    if not isinstance(loads, LoadResult) or loads.field is None:
        return None
    surface = loads.field
    triangles, origin = surface.triangles()
    names = [k for k in CAMPOS if k in surface.fields] + [k for k in surface.fields if k not in CAMPOS]
    fields = [{"name": k, "label": label(k), "signed": bool(CAMPOS.get(k, ("", "", True))[2]),
               "values": np.asarray(surface.fields[k], float).tolist()} for k in names]
    vectors = [{"name": layer.name, "unit": layer.unit, "color": list(layer.color),
                "origins": np.round(np.asarray(layer.origins, float), 5).ravel().tolist(),
                "vectors": np.asarray(layer.vectors, float).ravel().tolist()} for layer in surface.vectors]
    rest = []
    aircraft = table.get("_aircraft")
    if aircraft is not None:
        from aerosim.model.geometry import aircraft_meshes
        rest = _mesh_list([part for parts in aircraft_meshes(aircraft).values() for part in parts
                           if part[1] not in ("wing", "htail", "vtail", "control", "device")])
    meta = loads.meta
    info = [meta.get("caso", "")]
    if meta.get("modificadores"):
        info.append("modificadores: " + "; ".join(meta["modificadores"]))
    info.append(f"fonte: {meta.get('fonte', '?')}")
    info += ["⚠ " + a for a in meta.get("avisos", [])]
    return {"vertices": np.round(np.asarray(surface.vertices, float), 5).ravel().tolist(),
            "triangles": np.asarray(triangles, int).ravel().tolist(), "face": np.asarray(origin, int).tolist(),
            "fields": fields, "vectors": vectors, "rest": rest, "info": " · ".join(t for t in info if t),
            "camera": dict(table.get("_camera") or {})}


def _view(aircraft, markers: dict | None = None) -> dict:
    """a vista 3D da GUI PyQt (`AircraftView`): as malhas de `aerosim.model.geometry` e os marcadores"""
    from aerosim.model.geometry import aircraft_meshes
    meshes = [part for parts in aircraft_meshes(aircraft).values() for part in parts]
    return {"meshes": _mesh_list(meshes), "markers": dict(markers or {})}


def _plain(value: Any):
    """o que o json não conhece: números do numpy, vetores, o resto como texto"""
    if hasattr(value, "tolist"):
        return value.tolist()
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return str(value)


class _Lines:
    """a saída da ponte no navegador: as linhas ficam numa lista em vez de ir para um arquivo"""

    def __init__(self):
        self.lines: list[str] = []

    def write(self, text: str) -> None:
        self.lines.append(text)

    def flush(self) -> None:
        pass


_browser: Bridge | None = None


def start_in_browser(core_path: str, design_dir: str | None = None) -> None:
    """abre a ponte do navegador com o núcleo em `core_path` (o side module que a página carregou)"""
    global _browser
    from aerosim.backend.zig import ZigBackend
    from aerosim.manager import SimulationManager
    _browser = Bridge(SimulationManager(ZigBackend(core_path)), _Lines(), design_dir)


def call_in_browser(line: str) -> str:
    """um pedido inteiro, na hora (o Pyodide não tem thread): devolve a linha da resposta, sem as de progresso.
    O cancelamento não tem efeito aqui, porque nada roda enquanto uma conta não acaba"""
    request = json.loads(line)
    if request.get("op") == "cancel":
        return ""
    out = _browser.out
    out.lines.clear()
    _browser.answer(request)
    for text in reversed(out.lines):
        if '"progress"' not in text[:40]:
            return text.strip()
    return json.dumps({"id": request.get("id"), "ok": False, "error": "sem resposta"})


def main() -> None:
    # a saída padrão fica só para a ponte: o que o Python e o C imprimirem vai para a saída de erro
    out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    from aerosim.manager import SimulationManager
    bridge = Bridge(SimulationManager(), out, os.environ.get("AEROSIM_SPRINT") or None)
    bridge.send({"id": 0, "ok": True, "ready": True})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            bridge.send({"id": None, "ok": False, "error": f"JSON inválido: {error}"})
            continue
        bridge.handle(request)


if __name__ == "__main__":
    main()
