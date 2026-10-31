"""A ponte com a tela em Zig (`aerosim/bridge.py`): o processo responde aos pedidos por JSON, e a curva que chega
na tela é a mesma que o Simulation Manager devolve rodando direto (o mesmo código, sem conta no caminho)."""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from aerosim.data.projects import load_file
from aerosim.manager import SimulationManager

ROOT = Path(__file__).resolve().parents[2]
PLANE = ROOT / "data" / "aircraft" / "S1223_monomotor_EH_convencional_Joinville.json"
VALUES = {"whole": False, "use_zig": False, "use_zig_llt": False, "a0": 0.0, "a1": 12.0, "da": 2.0}


def _talk(requests: list[dict]) -> list[dict]:
    """manda os pedidos e lê as respostas (sem as linhas de progresso) até a última"""
    environment = {**os.environ, "AEROSIM_SPRINT": str(ROOT / ".nao_existe_sprint")}   # sem o projeto de quem roda
    process = subprocess.Popen([sys.executable, "-m", "aerosim.bridge"], cwd=ROOT, env=environment, text=True,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        replies = [json.loads(process.stdout.readline())]
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            while True:
                reply = json.loads(process.stdout.readline())
                if "progress" not in reply:
                    break
            replies.append(reply)
        return replies
    finally:
        process.stdin.close()
        process.wait(timeout=30)


@pytest.fixture(scope="module")
def replies():
    return _talk([{"id": 1, "op": "open", "path": str(PLANE)},
                  {"id": 2, "op": "layout"},
                  {"id": 3, "op": "specs", "name": "wings", "values": VALUES},
                  {"id": 4, "op": "run", "name": "wings", "values": VALUES},
                  {"id": 5, "op": "run", "name": "nao_existe"}])


def test_ready_and_layout(replies):
    """as abas na arrumação da GUI PyQt: a Aerodinâmica com Perfis, Projetar e Analisar (a aba Asas), Montagem no fim"""
    assert replies[0] == {"id": 0, "ok": True, "ready": True}
    assert replies[1]["ok"] and replies[1]["id"] == 1
    areas = {a["title"]: a for a in replies[2]["areas"]}
    aero = [(t["title"], t["kind"], t["name"]) for t in areas["Aerodinâmica"]["tabs"]]
    assert aero == [("Perfis", "stage", "perfis"), ("Projetar", "stage", "asa"), ("Analisar", "sim", "wings")]
    assert replies[2]["areas"][-1]["tabs"][0]["kind"] == "assembly"


def test_specs_carry_the_form(replies):
    specs = replies[3]
    keys = {p["key"]: p for p in specs["params"]}
    assert keys["use_lltdrek"]["kind"] == "bool" and keys["use_lltdrek"]["default"] is True
    assert keys["source"]["kind"] == "choice" and keys["source"]["rebuild"]
    assert any(p["kind"] == "2d" for p in specs["plots"])


def test_curve_is_the_managers(replies):
    """a curva C_L × α do lltdrek que chega pela ponte é, número a número, a do manager rodando direto"""
    run = replies[4]
    assert run["ok"], run
    chart = next(p for p in run["plots"] if p["key"] == "pol_CL")
    bridged = next(c for c in chart["curves"] if c["name"] == "lltdrek")
    direct = SimulationManager().run("wings", load_file(str(PLANE)), dict(VALUES))
    table = direct.series["polar_lltdrek"]
    assert bridged["x"] == [float(a) for a in table["alpha"]]
    assert bridged["y"] == [float(c) for c in table["CL"]]


def test_error_keeps_the_bridge_alive(replies):
    assert replies[5]["ok"] is False and "nao_existe" in replies[5]["error"]


def test_plot_style_reaches_the_screen():
    """os pedidos de desenho da GUI PyQt (_color, _fill, _symbol, _vspan, _ylim) chegam à tela em Zig como campos"""
    from aerosim.bridge import PALETTE, _plot
    from aerosim.interfaces.simulation import PlotSpec, SimResult
    series = {"a": {"V": [10, 20], "P": [1, 2], "_color": "#123456", "_width": 3, "_fill": "Q", "Q": [0, 0],
                    "_strong": True},
              "b": {"V": [15], "P": [1.5], "_symbol": "*", "_size": 12, "_nolegend": True},
              "faixa": {"_vspan": [11, 12], "_label": "estol"},
              "escala": {"_ylim": [0, 5]}}
    spec = PlotSpec("p", "P", "V", ("P",), source="series:*")
    out = _plot(spec, SimResult(series=series))
    curves = {c["name"]: c for c in out["curves"]}
    assert curves["a"]["color"] == "#123456" and curves["a"]["width"] == 3.0
    assert curves["a"]["fill"] == [0.0, 0.0] and curves["a"]["strong"] is True
    assert curves["b"]["marker"] == "*" and curves["b"]["size"] == 12.0 and curves["b"]["legend"] is False
    assert curves["b"]["color"] in PALETTE                      # sem cor pedida: a paleta da PyQt
    assert curves["estol"]["vspan"] and curves["estol"]["x"] == [11.0, 12.0]
    assert out["ylim"] == [0.0, 5.0]



def test_track_keeps_one_color_per_leg():
    """a trajetória 3D chega à tela em Zig com uma linha por etapa na cor dela, os eventos como pontos e as
    silhuetas como pares de pontos, com a altura exagerada como na GUI PyQt"""
    from aerosim.bridge import _plot
    from aerosim.interfaces.simulation import PlotSpec, SimResult
    series = {"t3_decolagem": {"e": [0, 0], "n": [0, 100], "h": [0, 10], "_color": "#d62728"},
              "t3_cruzeiro": {"e": [0, 50], "n": [100, 200], "h": [10, 10], "_color": "#1f77b4"},
              "t3_★ decolou": {"e": [0], "n": [50], "h": [1], "_symbol": "star", "_color": "#ffcc00", "_size": 18},
              "t3_✈ cruzeiro": {"e": [0, 0], "n": [150, 150], "h": [10, 10], "oe": [-1, 1], "on": [0, 0],
                                "oh": [0, 0], "_segments": 1, "_nolegend": 1, "_color": "#1f77b4"}}
    spec = PlotSpec("t3", "Trajetória 3D", "e", ("n",), source="series:t3_*", kind="3d", z="h")
    track = _plot(spec, SimResult(series=series))["track"]
    lines = {line["name"]: line for line in track["lines"]}
    assert lines["decolagem"]["color"] == "#d62728" and lines["cruzeiro"]["color"] == "#1f77b4"
    assert lines["decolou"]["kind"] == "points" and lines["decolou"]["marker"] == "star"
    assert lines["✈ cruzeiro"]["kind"] == "segments" and not lines["✈ cruzeiro"]["legend"]
    scale = track["scale"]                                   # 0,25 × 200 m / 10 m = 5
    assert scale == 5 and lines["cruzeiro"]["points"][2] == 10 * scale
    assert lines["✈ cruzeiro"]["points"][:3] == [-1.0, 150.0, 10.0 * scale]
