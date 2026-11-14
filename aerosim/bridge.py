"""O adaptador dos métodos de fora do núcleo: lltdrek, AeroSandbox (VLM, AeroBuildup, LiftingLine) e AVL, que são
bibliotecas em Python. A tela em Zig faz todo o resto. Aqui só se recebe a geometria do avião em JSON (o mesmo
formato do arquivo, já com as asas escolhidas), se roda o método pedido e se devolvem os coeficientes. Nada é
desenhado aqui. A conversa é por uma mensagem JSON por linha, na entrada e na saída padrão: a tela abre
`python -m aerosim.bridge`.

Pedidos (cada um com um `id`, que volta na resposta; cada um roda na sua thread):
  {"op": "polar", "solver": "lltdrek", "aircraft": {...}, "V": 12, "alphas": [...], "alpha_d": 10,
   "ref": [x, y, z], "section": "modelo", "n_span": 12, "n_chord": 0}
      a polar do método (lltdrek, asb_vlm, asb_buildup, asb_ll ou avl): alpha, CL, CD, Cm, CDi, as derivadas e, no
      lltdrek, a carga ao longo da asa principal no α das derivadas
  {"op": "loads", "method": "vlm_asb", "aircraft": {...}, "V": 12, "alpha": 4, "beta": 0, "de": 0, "da": 0,
   "dr": 0, "rho": 1.225, "n_span": 0, "n_chord": 0}
      a carga ao longo de cada superfície pelo VLM do AeroSandbox: s, L (N/m), α efetivo, sustentação e arrasto
  {"op": "cancel", "target": id}                    sem efeito (a conta de fora não para no meio)

Resposta: {"id", "ok": true, ...} ou {"id", "ok": false, "error": "texto"}. O que as bibliotecas imprimem na saída
padrão (inclusive o C) vai para a saída de erro: a saída padrão é só da ponte.

No navegador não há processo nem thread: o Pyodide roda este módulo na própria página, e a página chama
`call_in_browser` com cada pedido (`aerosim/gui/web/python.html`).
"""
from __future__ import annotations

import json
import math
import os
import sys
import threading
import traceback
from types import SimpleNamespace
from typing import Any

import numpy as np

# o solver de cada chave da tela (`solvers` de aerosim/manager/simulations/wings.zig)
SOLVERS = ("lltdrek", "asb_vlm", "asb_buildup", "asb_ll", "avl")


def solver(name: str):
    """o método de fora pela chave da tela"""
    from aerosim.aero.asb_solver import AsbBuildupSolver, AsbLiftingLineSolver, AsbVLMSolver
    from aerosim.aero.avl_solver import AvlSolver
    from aerosim.aero.lltdrek_solver import LltdrekSolver
    known = {"lltdrek": LltdrekSolver, "asb_vlm": AsbVLMSolver, "asb_buildup": AsbBuildupSolver,
             "asb_ll": AsbLiftingLineSolver, "avl": AvlSolver}
    if name not in known:
        raise ValueError(f"método de fora desconhecido: {name!r} ({' | '.join(SOLVERS)})")
    return known[name]()


def model_of(data: dict):
    """o modelo universal do avião que a tela mandou"""
    from aerosim.model.aircraft import Aircraft
    from aerosim.model.serialize import from_dict
    from aerosim.model.universal import build_model
    return build_model(from_dict(Aircraft, data))


def polar(request: dict) -> dict:
    """a polar de um método de fora"""
    from aerosim.interfaces.aero import AeroCase
    method = solver(request["solver"])
    why = method.available()
    if why:
        raise RuntimeError(why)
    model = model_of(request["aircraft"])
    case = AeroCase(V=float(request["V"]), alphas=np.asarray(request["alphas"], float),
                    alpha_d=float(request.get("alpha_d", 2.0)), ref=tuple(request.get("ref", (0.0, 0.0, 0.0))),
                    rho=model.aircraft.environment.rho, section=request.get("section", "modelo"),
                    n_span=int(request.get("n_span", 20)), n_chord=int(request.get("n_chord", 0)))
    result = method.solve(model, case)
    out = {"alpha": result.alpha, "CL": result.CL, "CD": result.CD, "Cm": result.Cm, "CDi": result.CDi,
           "derivs": result.derivs, "elapsed": result.elapsed, "source": getattr(result, "source", ""),
           "notes": result.notes}
    if result.span is not None:
        out["span"] = {"y": result.span["y"], "cl": result.span["cl"], "ccl": result.span["ccl"],
                       "chord": model.c, "wing": model.wing.name if model.wing is not None else ""}
    return out


def loads(request: dict) -> dict:
    """a carga ao longo das superfícies pelo VLM do AeroSandbox"""
    from aerosim.aero.asb_solver import AsbVLMLoads
    if request.get("method", "vlm_asb") != "vlm_asb":
        raise ValueError(f"método de carga de fora desconhecido: {request.get('method')!r} (vlm_asb)")
    method = AsbVLMLoads(int(request.get("n_span", 0)), int(request.get("n_chord", 0)))
    why = method.available()
    if why:
        raise RuntimeError(why)
    model = model_of(request["aircraft"])
    point = SimpleNamespace(V=float(request["V"]), alpha=float(request["alpha"]), beta=float(request.get("beta", 0)),
                            de=float(request.get("de", 0)), da=float(request.get("da", 0)),
                            dr=float(request.get("dr", 0)), rho=float(request.get("rho", 1.225)))
    surfaces, notes = method.strips(model, point)
    return {"surfaces": surfaces, "notes": notes, "source": method.source}


def plain(value: Any):
    """o que o JSON não sabe escrever: vetores do numpy viram listas e NaN vira null"""
    if isinstance(value, np.ndarray):
        return [plain(v) for v in value.tolist()]
    if isinstance(value, (np.floating, float)):
        return float(value) if math.isfinite(value) else None
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    return value


def answer(request: dict) -> dict:
    """a resposta inteira de um pedido"""
    op = request.get("op")
    try:
        if op == "polar":
            body = polar(request)
        elif op == "loads":
            body = loads(request)
        else:
            raise ValueError(f"pedido desconhecido: {op!r} (polar ou loads)")
        return {"id": request.get("id"), "ok": True, **plain(body)}
    except Exception as error:     # a tela mostra o erro; a ponte segue viva
        traceback.print_exc(file=sys.stderr)
        return {"id": request.get("id"), "ok": False, "error": f"{type(error).__name__}: {error}"}


def call_in_browser(line: str) -> str:
    """um pedido inteiro, na hora (o Pyodide não tem thread): devolve a linha da resposta"""
    request = json.loads(line)
    if request.get("op") == "cancel":
        return ""
    return json.dumps(answer(request), ensure_ascii=False, allow_nan=False)


def main() -> None:
    # a saída padrão fica só para a ponte: o que o Python e o C imprimirem vai para a saída de erro
    out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    lock = threading.Lock()

    def send(message: dict) -> None:
        line = json.dumps(message, ensure_ascii=False, allow_nan=False)
        with lock:
            out.write(line + "\n")
            out.flush()

    send({"id": 0, "ok": True, "ready": True})
    # a tela manda UTF-8; no Windows a entrada padrão lia na página de código do sistema
    sys.stdin.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            send({"id": None, "ok": False, "error": f"JSON inválido: {error}"})
            continue
        if request.get("op") == "cancel":
            continue
        threading.Thread(target=lambda r=request: send(answer(r)), daemon=True).start()


if __name__ == "__main__":
    main()
