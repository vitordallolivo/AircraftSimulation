"""A ponte com a tela em Zig (`aerosim/bridge.py`): o processo responde aos pedidos por JSON, e a curva que chega
na tela é a mesma que o Simulation Manager devolve rodando direto (o mesmo código, sem conta no caminho)."""
import json
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
    process = subprocess.Popen([sys.executable, "-m", "aerosim.bridge"], cwd=ROOT, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
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
                  {"id": 2, "op": "list"},
                  {"id": 3, "op": "specs", "name": "wings", "values": VALUES},
                  {"id": 4, "op": "run", "name": "wings", "values": VALUES},
                  {"id": 5, "op": "run", "name": "nao_existe"}])


def test_ready_and_list(replies):
    assert replies[0] == {"id": 0, "ok": True, "ready": True}
    assert replies[1]["ok"] and replies[1]["id"] == 1
    names = [s["name"] for s in replies[2]["sims"]]
    assert "wings" in names


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
