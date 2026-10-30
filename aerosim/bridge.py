"""Ponte entre a tela em Zig (raylib) e os managers em Python: uma mensagem JSON por linha, na entrada e na saída
padrão. A tela abre `python -m aerosim.bridge` e pede; aqui se chama o Simulation Manager (que chama o núcleo) e se
devolve o resultado já pronto para desenhar. Nada de conta aqui: só se traduz o pedido e o `SimResult`.

Pedidos (cada um com um `id`, que volta na resposta):
  {"op": "open", "path": "avião.json"}                 abre o avião (sem pedido: o avião vazio)
  {"op": "list"}                                        as abas: nome, título, descrição, área
  {"op": "specs", "name": "wings", "values": {...}}     campos (`ParamSpec`) e gráficos (`PlotSpec`) da aba
  {"op": "run", "name": "wings", "values": {...}}       roda; antes da resposta vêm linhas {"id", "progress", "message"}
  {"op": "cancel"}                                      para a rodada em andamento (sem resposta)

Resposta: {"id", "ok": true, ...} ou {"id", "ok": false, "error": "texto"}. Os gráficos do resultado vêm com as
curvas já resolvidas (a tabela de cada `series:<prefixo>*` vira uma curva com nome, x e y), como a GUI PyQt faz
em `aerosim/gui/widgets/plots.py`.

O que as bibliotecas imprimem na saída padrão (inclusive o C) vai para a saída de erro: a saída padrão é só da ponte.
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

from aerosim.interfaces.simulation import CancelledError, ISimulationManager, PlotSpec, SimResult

FORM_KINDS = ("float", "int", "bool", "choice")      # os tipos de campo que a tela em Zig desenha por enquanto
PLOT_KINDS = ("2d",)                                  # os tipos de gráfico idem (3d e loads3d: só na GUI PyQt)


class Bridge:
    def __init__(self, manager: ISimulationManager, out):
        self.manager = manager
        self.out = out
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.worker: threading.Thread | None = None
        from aerosim.model.aircraft import Aircraft
        self.aircraft = Aircraft()

    # ------------------------------------------------------------------ saída
    def send(self, message: dict) -> None:
        line = json.dumps(message, ensure_ascii=False, default=_plain, allow_nan=False)
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()

    def reply(self, request: dict, **fields) -> None:
        self.send({"id": request.get("id"), "ok": True, **fields})

    def fail(self, request: dict, error: str) -> None:
        self.send({"id": request.get("id"), "ok": False, "error": error})

    # ------------------------------------------------------------------ pedidos
    def handle(self, request: dict) -> None:
        op = request.get("op")
        try:
            if op == "open":
                from aerosim.data.projects import load_file
                self.aircraft = load_file(request["path"])
                self.reply(request, name=getattr(self.aircraft, "name", "") or os.path.basename(request["path"]))
            elif op == "list":
                self.reply(request, sims=[{"name": s.name, "title": s.title, "description": s.description,
                                           "area": s.area} for s in self.manager.simulations()])
            elif op == "specs":
                sim = self.manager.get(request["name"])
                values = request.get("values") or {}
                self.reply(request, params=[_param(p) for p in sim.parameters_for(self.aircraft, values)],
                           plots=[_plot_spec(p) for p in sim.plots_for(self.aircraft, values)],
                           description=sim.description)
            elif op == "run":
                if self.worker is not None and self.worker.is_alive():
                    self.fail(request, "outra rodada ainda em andamento")
                    return
                self.cancel.clear()
                self.worker = threading.Thread(target=self.run, args=(request,), daemon=True)
                self.worker.start()
            elif op == "cancel":
                self.cancel.set()
            else:
                self.fail(request, f"pedido desconhecido: {op!r}")
        except Exception as error:     # a tela mostra o erro; a ponte segue viva
            traceback.print_exc(file=sys.stderr)
            self.fail(request, f"{type(error).__name__}: {error}")

    def run(self, request: dict) -> None:
        name = request["name"]
        values = request.get("values") or {}
        progress = lambda fraction, message: self.send({"id": request.get("id"), "progress": float(fraction),
                                                        "message": str(message)})
        try:
            sim = self.manager.get(name)
            result = self.manager.run(name, self.aircraft, values, on_progress=progress, cancel=self.cancel)
            plots = [_plot(spec, result) for spec in sim.plots_for(self.aircraft, values)]
            self.reply(request, status=result.status, summary=result.summary,
                       checks=[asdict(check) for check in result.checks], plots=plots)
        except CancelledError:
            self.fail(request, "cancelado")
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            self.fail(request, f"{type(error).__name__}: {error}")


# ---------------------------------------------------------------------- tradução das specs e do resultado
def _param(p) -> dict:
    return {"key": p.key, "label": p.label, "kind": p.kind if p.kind in FORM_KINDS else "unsupported",
            "default": p.default, "minimum": p.minimum, "maximum": p.maximum, "unit": p.unit,
            "choices": [str(c) for c in p.choices], "group": p.group, "help": p.help, "rebuild": p.rebuild}


def _plot_spec(p: PlotSpec) -> dict:
    return {"key": p.key, "title": p.title, "xlabel": p.xlabel, "ylabel": p.ylabel,
            "kind": p.kind if p.kind in PLOT_KINDS else "unsupported"}


def _plot(spec: PlotSpec, result: SimResult) -> dict:
    """as curvas de um gráfico: uma por tabela e por coluna y (só as colunas que existem e são numéricas)"""
    out = _plot_spec(spec)
    out["curves"] = curves = []
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
    for label, table in tables:
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
    return out


def _numbers(column) -> list | None:
    try:
        values = [float(v) for v in column]
    except (TypeError, ValueError):
        return None
    return [v if math.isfinite(v) else None for v in values]


def _plain(value: Any):
    """o que o json não conhece: números do numpy, vetores, o resto como texto"""
    if hasattr(value, "tolist"):
        return value.tolist()
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return str(value)


def main() -> None:
    # a saída padrão fica só para a ponte: o que o Python e o C imprimirem vai para a saída de erro
    out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    from aerosim.manager import SimulationManager
    bridge = Bridge(SimulationManager(), out)
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
