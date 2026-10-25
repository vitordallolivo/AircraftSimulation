"""A janela do aeroopt: o .toml inteiro nos campos, a rodada ao vivo (tabela, pontos, mapa) e o avião escolhido."""
import math
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
QtWidgets = pytest.importorskip("PyQt6.QtWidgets")


@pytest.fixture(scope="module")
def app():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def _wait(app, cond, limit=300.0):
    t0 = time.time()
    while not cond() and time.time() - t0 < limit:
        app.processEvents()
        time.sleep(0.02)
    assert cond()


def test_scoring_editor_holds_the_whole_toml(app):
    from aeroopt import scoring as sc
    from aeroopt.gui import ScoringEditor
    ed = ScoringEditor()
    ed.set_spec("sae_br_2026_micro")
    ref = sc.ScoringFile("sae_br_2026_micro")
    assert ed.fields() == ref.data                                 # os campos guardam o arquivo inteiro
    assert ed.scoring().program() == ref.program()
    ed.consts.item(0, 1).setText("1.0")                            # f_pv = 1,0: a nota cai 5 %
    row = dict(c_lapes=1.0, c_liq=1.2, pv=0.5, m_bat=0.3, s_to=3.5, b=1.8)
    a, b = sc.evaluate(ref, row)[0]["nota"], sc.evaluate(ed.scoring(), row)[0]["nota"]
    assert b == pytest.approx(a / 1.05)
    ed.score.setText("p_m - ")
    with pytest.raises(sc.ScoringError):
        ed.scoring()
    ed.set_spec("MTOW")
    assert ed.scoring().quantities() == ["mtow"]


def test_window_runs_and_shows_each_candidate(app):
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    pr.params["categorias"] = ["asa alta", "cauda em V"]
    for v in pr.variables:
        if v.key == "power.propeller":
            v.options = ["Genérica 13x6.5"]
        if v.key == "wing.area":                                  # a partir de 0,55 m² a bateria equilibra o CG
            v.lo, v.hi = 0.55, 0.6
    w = AeroOptWindow(p, pr)
    w.evals.setValue(2)
    w.workers.setValue(1)
    w.six.setChecked(False)
    seen = []
    w.start()
    _wait(app, lambda: bool(w._threads))
    w._threads[0][1].item.connect(lambda st, r: seen.append(st))
    _wait(app, lambda: not w._threads)
    assert len(w.rows) == 2 and w.funnel["superfícies"][0] == 2
    assert {"superfícies", "nota"} <= set(seen)
    assert len(w.points) == 4                                       # 2 pontos de projeto × 2 configurações
    assert w.cfg_tab.rowCount() == 2 and w.stage_tab.rowCount() == 2
    best = max(w.rows.values(), key=lambda r: r["nota"])
    assert w.selected == best["name"] and math.isfinite(best["nota"])
    assert w.sel_tab.rowCount() > 5
    w.ax_x.setCurrentText("envergadura (m)")                       # o mapa troca de eixos sem rodar de novo
    w.ax_y.setCurrentText("nota")
    _wait(app, lambda: not w._threads)


def test_csv_has_every_evaluation_in_order(tmp_path):
    import csv

    from aeroopt import export
    from aeroopt import stages as sg
    from aeroopt.gui import example_project
    p, pr = example_project()
    pr.params["categorias"] = ["asa alta", "cauda em V"]
    pr.variable("power.propeller").options = ["Genérica 13x6.5"]
    pr.variable("wing.area").lo, pr.variable("wing.area").hi = 0.55, 0.6
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=3))
    export.write(res.rows, str(tmp_path))
    with open(tmp_path / "avaliacoes.csv", encoding="utf-8-sig") as f:
        ev = list(csv.reader(f, delimiter=";"))
    with open(tmp_path / "configuracoes.csv", encoding="utf-8-sig") as f:
        cf = list(csv.reader(f, delimiter=";"))
    head = ev[0]
    assert head[:3] == ["configuração nº", "avaliação nº", "configuração"]
    assert {"categoria", "power.propeller", "wing.span", "wing.area", "MTOW pista (kg)", "fecha", "motivo"} <= set(head)
    assert len(ev) - 1 == sum(len(r["history"]) for r in res.rows) == 6     # 3 por configuração
    assert [(r[0], r[1]) for r in ev[1:]] == [("1", "1"), ("1", "2"), ("1", "3"), ("2", "1"), ("2", "2"), ("2", "3")]
    assert len(cf) == 3 and "nota" in cf[0] and "fator: f_bat" in cf[0]
    assert "," in ev[1][head.index("wing.span")]                            # vírgula decimal


def test_empty_project_runs_and_constraints_are_editable(app):
    from aeroopt.gui import AeroOptWindow
    w = AeroOptWindow()                                       # sem projeto: os rascunhos de um projeto novo
    pr = w.read_problem()
    assert pr.constraints and w.cons.t.rowCount() == len(pr.constraints)
    i = next(i for i, c in enumerate(pr.constraints) if c.key == "s_to")
    w.cons.t.item(i, 3).setText("40")
    w.cons._add("b", "≤", 1.8, True)
    pr = w.read_problem()
    assert next(c for c in pr.constraints if c.key == "s_to").value == 40.0
    assert pr.constraints[-1].key == "b" and pr.constraints[-1].value == 1.8
    for v in w.problem.variables:
        v.free = False
    w.vars.set_problem(w.problem)
    w.evals.setValue(1)
    w.workers.setValue(1)
    w.six.setChecked(False)
    w.start()
    _wait(app, lambda: not w._threads)
    assert len(w.rows) == 1 and w.run_dir and os.path.exists(os.path.join(w.run_dir, "avaliacoes.csv"))
    import shutil
    shutil.rmtree(os.path.dirname(w.run_dir), ignore_errors=True) if "rodadas_aeroopt" in w.run_dir else None
