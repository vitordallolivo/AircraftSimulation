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
