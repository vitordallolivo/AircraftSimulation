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
    w.set_method("decolagem", "pista")
    seen = []
    w.start()
    _wait(app, lambda: bool(w._threads))
    w._threads[0][1].item.connect(lambda st, r: seen.append(st))
    _wait(app, lambda: not w._threads)
    assert len(w.rows) == 2 and w.funnel["superfícies"][0] == 2
    assert {"superfícies", "nota"} <= set(seen)
    assert len(w.points) == 4                                       # 2 pontos de projeto × 2 configurações
    assert w.cfg_tab.rowCount() == 2 and w.stage_tab.rowCount() == 4            # geometria, voa, superfícies, nota
    assert w.funnel["geometria"] == [2, 2, 2] and all(r["geração"] == 1 for r in w.rows.values())
    best = max(w.rows.values(), key=lambda r: r["nota"])
    assert w.selected == best["name"] and math.isfinite(best["nota"])
    assert w.sel_tab.rowCount() > 5
    w.ax_x.setCurrentText("envergadura (m)")                       # o mapa troca de eixos sem rodar de novo
    w.ax_y.setCurrentText("nota")
    # as variáveis do problema também são eixos: livres primeiro, depois as fixas, e a cor segue a nota
    datas = [w.ax_x.itemData(i) for i in range(w.ax_x.count()) if w.ax_x.itemData(i)]
    free = ["var:" + v.key for v in w.read_problem().variables if v.free]
    assert datas[:len(free)] == free and "res:nota" in datas
    assert w.ax_x.currentData() == free[0] or w.ax_x.currentText() == "envergadura (m) · resultado"
    assert any(w.ax_x.itemText(i).endswith(" · fixa") for i in range(w.ax_x.count()))
    w.ax_x.setCurrentIndex(w.ax_x.findData(free[0]))
    xs, _ = w._coords(list(w.rows.values()), free[0])
    assert len(xs) == 2 and all(math.isfinite(x) for x in xs)
    lst = next("var:" + v.key for v in w.read_problem().variables if v.kind == "lista")
    w.ax_y.setCurrentIndex(w.ax_y.findData(lst))                   # uma lista vira índice com o nome no eixo
    ys, names = w._coords(list(w.rows.values()), lst)
    assert names and all(0 <= y < len(names) for y in ys)
    # os gráficos do melhor avião aparecem sozinhos, uma aba por análise, sem formulário
    from aeroopt.gui import BEST_ANALYSES
    best = max(w.rows.values(), key=lambda r: (r["valido"], r["nota"]))
    _wait(app, lambda: w._best_job is None and w.best_tabs.count() == len(BEST_ANALYSES))
    assert w._best_shown == best["name"]
    assert [w.best_tabs.tabText(i) for i in range(w.best_tabs.count())] == [t for _, t in BEST_ANALYSES]
    # o avião refeito depois da rodada não segura o Otimizar (antes ele ficava desligado em 100 %)
    _wait(app, lambda: not w._side)
    assert w.run_b.isEnabled() and not w.stop_b.isEnabled()
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
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=3, geometry=False))
    export.write(res.rows, str(tmp_path))
    with open(tmp_path / "avaliacoes.csv", encoding="utf-8-sig") as f:
        ev = list(csv.reader(f, delimiter=";"))
    with open(tmp_path / "configuracoes.csv", encoding="utf-8-sig") as f:
        cf = list(csv.reader(f, delimiter=";"))
    head = ev[0]
    assert head[:4] == ["configuração nº", "avaliação nº", "geração", "configuração"]
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
    w.cons.t.cellWidget(i, 3).setValue(40)
    w.cons._add("V_S", "≤", 13.0, True)
    pr = w.read_problem()
    assert next(c for c in pr.constraints if c.key == "s_to").value == 40.0
    assert pr.constraints[-1].key == "V_S" and pr.constraints[-1].value == 13.0
    w.cons._add("b", "≤", 1.8, True)                         # envergadura é variável: não entra como restrição
    assert w.read_problem().constraints[-1].key == "V_S"
    for v in w.problem.variables:
        v.free = False
    w.vars.set_problem(w.problem)
    w.evals.setValue(1)
    w.workers.setValue(1)
    w.set_method("decolagem", "pista")
    w.start()
    _wait(app, lambda: not w._threads)
    assert len(w.rows) == 1 and w.run_dir and os.path.exists(os.path.join(w.run_dir, "avaliacoes.csv"))
    import shutil
    shutil.rmtree(os.path.dirname(w.run_dir), ignore_errors=True) if "rodadas_aeroopt" in w.run_dir else None


def test_lists_by_region_and_catalog_parts(app, tmp_path):
    """o .dat acrescentado entra no projeto e nas listas; cada região marcada vira uma lista livre; nada marcado =
    o do avião"""
    from aeroopt import stages as sg
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr)
    dat = tmp_path / "meu.dat"
    dat.write_text("MEU PERFIL\n1 0\n0.5 0.06\n0 0\n0.5 -0.02\n1 0\n")
    ch = w.vars.choices
    ch["wing.airfoil"].tick("wing.airfoil", ["NACA 2412"])
    name = ch["wing.airfoil"].add_dat(str(dat))
    assert name == "MEU PERFIL" and p.airfoil(name) is not None
    assert ch["wing.airfoil"].checked("wing.airfoil") == ["NACA 2412"]            # as marcas de antes ficam
    lw = ch["tail.airfoil"].lists["tail.airfoil"]
    assert name in [lw.item(i).data(256) for i in range(lw.count())]            # e o perfil entra nas outras listas
    ch["tail.airfoil"].tick("tail.airfoil", [name])
    bat = ch["power.battery"].lists["power.battery"].item(0).data(256)
    ch["power.battery"].tick("power.battery", [bat])
    out = w.read_problem()
    v = out.variable("tail.airfoil")
    assert v.free and v.options == [name] and v.kind == "lista"
    assert out.variable("power.battery").options == [bat]
    assert not out.variable("wing.airfoil_tip").free
    items = sg.configurations(p, out)
    assert all(i.values["tail.airfoil"] == name for i in items)
    q, _ = sg.candidate(p, items[0].values)
    assert q.tail_draft.tail_airfoil == name and q.power_draft.battery == bat
    w.problem = out
    w._summaries(out)
    assert name in w.summary["variáveis"].text() and bat in w.summary["variáveis"].text()


def test_constraint_on_a_variable_becomes_its_bound():
    """b ≤ 1,8 com a envergadura variável: vira o limite superior dela e sai das restrições"""
    import aeroopt
    from aeroopt.gui import example_project
    from aerosim.interfaces.optim import OptConstraint
    p, pr = example_project()
    pr.constraints.append(OptConstraint("b", "≤", 1.7))
    pr.constraints.append(OptConstraint("S", "≥", 0.45))
    aeroopt.fold_bounds(pr, p)
    assert not any(c.key in ("b", "S") for c in pr.constraints)
    assert pr.variable("wing.span").hi == 1.7 and pr.variable("wing.area").lo == 0.45
    pr.variable("wing.span").free = False
    pr.constraints.append(OptConstraint("b", "≤", 1.2))                     # o avião tem 1,75 m
    with pytest.raises(ValueError, match="fora dos limites"):
        aeroopt.fold_bounds(pr, p)


def test_left_panel_is_buttons_and_settings_go_with_the_problem(app, tmp_path):
    """tudo da esquerda abre num submenu; a geometria fica nas restrições, as etapas e o método de cada uma na
    Configuração, e tudo vai no .opt.json"""
    import aeroopt
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr)
    assert set(w.menus) == {"pontuação", "variáveis", "restrições", "categorias", "configuração"}
    assert w.rot.window() is not w and w.scoring.window() is not w and w.cat_cb["asa alta"].window() is not w
    assert w.rot.window() is w.menus["restrições"] and w.evals.window() is w.menus["configuração"]
    assert set(w.method) == {"configurações", "voa", "superfícies", "decolagem"}
    w.rot.setValue(9.0)
    w.one_piece.setChecked(True)
    w.stab.setChecked(True)
    w.stab_level.setCurrentIndex(2)
    w.set_method("superfícies", "gerações")
    w.set_method("configurações", "todas")
    for c, cb in w.cat_cb.items():
        cb.setChecked(c == "asa alta")
    out = w.read_problem()
    assert out.params["geometria"]["rotação"] == 9.0 and out.params["geometria"]["uma_peça"]
    assert out.params["etapas"]["superfícies"] == "gerações" and out.params["categorias"] == ["asa alta"]
    g = w.geometry_params()
    assert g.rotation == 9.0 and g.connected and g.prop_clearance == pytest.approx(0.02)
    aeroopt.save(out, str(tmp_path / "x.opt.json"))
    w2 = AeroOptWindow(p, aeroopt.load(str(tmp_path / "x.opt.json")))
    assert w2.rot.value() == 9.0 and w2.methods()["superfícies"] == "gerações"
    assert w2.stab.isChecked() and w2.stab_level.currentData() == 3 and "nível 3" in w2.summary["restrições"].text()
    assert w2.methods()["configurações"] == "todas" and not w2.cat_cb["asa baixa"].isChecked()
    assert "9°" in w2.summary["restrições"].text() and "todas" in w2.summary["configuração"].text()
    w.problem = out
    w.scoring.set_spec("MTOW")                                   # Cancelar volta a pontuação ao que era
    w.scoring.restore(("sae_br_2026_micro", {}))
    assert w.scoring.spec() == "sae_br_2026_micro"


def test_every_aerosim_input_is_a_variable_and_lists_are_ticked(app):
    """o submenu das variáveis tem todo campo das etapas com faixa ou escolha; a lista se escolhe por marcação e o
    número pelos limites, e os dois viram variáveis do problema"""
    from aeroopt import inputs as inp
    from aeroopt import stages as sg
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr)
    assert set(w.vars.keys()) == set(inp.all_inputs()) and len(w.vars.keys()) > 60
    assert {"tail.VH", "power.gear", "rules.fuselage_width", "tail.tail_inverted"} <= set(w.vars.keys())
    w.vars.check("tail.VH", True, 0.35, 0.6)
    w.vars.choices["power.gear"].tick("power.gear", ["triciclo", "convencional"])
    w.vars.choices["tail.layout"].tick("tail.layout", ["em V"])
    out = w.read_problem()
    v = out.variable("tail.VH")
    assert v.free and (v.lo, v.hi) == (0.35, 0.6) and v.kind == "contínua" and v.group == "empenagem"
    assert out.variable("power.gear").options == ["triciclo", "convencional"]
    ax = dict(sg.axes(p, out))
    assert ax["power.gear"] == ["triciclo", "convencional"] and ax["tail.layout"] == ["em V"]
    q, cand = sg.candidate(p, {"power.gear": "convencional", "tail.VH": 0.5, "tail.tail_inverted": "sim"})
    assert cand.params.gear == "convencional" and cand.set.params.VH == 0.5 and cand.set.params.tail_inverted is True
    w._isolate("empenagem")
    assert {v.key for v in w.problem.free_variables() if v.kind != "lista"} == \
        {k for k, i in inp.all_inputs().items() if i.group == "empenagem" and i.kind != "lista"}


def test_saved_files_get_their_extension():
    from aeroopt.gui import with_ext
    assert with_ext("/x/as1", ".opt.json") == "/x/as1.opt.json"
    assert with_ext("/x/as1.opt.json", ".opt.json") == "/x/as1.opt.json"
    assert with_ext("/x/as1.JSON", ".opt.json") == "/x/as1.JSON"
    assert with_ext("/x/micro", ".toml") == "/x/micro.toml"


def test_window_with_synthetic_data_finds_the_known_best(app):
    """`python -m aeroopt --sintetico`: a janela inteira com os dados de teste, em segundos"""
    from aeroopt import synthetic as sy
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr, synthetic=True)
    w.workers.setValue(1)
    w.evals.setValue(16)
    w.start()
    _wait(app, lambda: not w._threads, 60)
    assert len(w.rows) == len(sy.expected(p, pr))
    best = max(w.rows.values(), key=lambda r: (r["valido"], r["nota"]))
    assert best["name"] == sy.best(p, pr) and "sintéticos" in w.windowTitle()
    _wait(app, lambda: not w._side and w._best_job is None)
