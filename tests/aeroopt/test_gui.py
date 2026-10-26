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
    pr.params["etapas"] = {}                                      # a cauda fica a de cada categoria (sem E&C)
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
    assert not hasattr(w, "eval_plot")             # sem o MTOW da pista: não é ele que pontua
    head = [w.cfg_tab.horizontalHeaderItem(j).text() for j in range(w.cfg_tab.columnCount())]
    assert "MTOW 6GDL" in head and "MTOW pista" not in head
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
    from aeroopt.gui import BEST_ANALYSES, SENS_TITLE
    best = max(w.rows.values(), key=lambda r: (r["valido"], r["nota"]))
    _wait(app, lambda: w._best_job is None and w.best_tabs.count() == len(BEST_ANALYSES) + 1)
    assert w._best_shown == best["name"]
    assert [w.best_tabs.tabText(i) for i in range(w.best_tabs.count())] == [t for _, t in BEST_ANALYSES] + [SENS_TITLE]
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
    """tudo da esquerda abre num submenu; a geometria fica nas restrições, as etapas, o método de cada uma e os
    aviões na Configuração, e tudo vai no .opt.json"""
    import aeroopt
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr)
    assert set(w.menus) == {"pontuação", "variáveis", "restrições", "configuração"}
    assert w.rot.window() is not w and w.scoring.window() is not w
    assert w.cat_cb["monoplano"].window() is w.menus["configuração"]
    assert {c for c, r in w.cat_row.items() if not r.isHidden()} == {"monoplano", "biplano", "tandem", "asa voadora"}
    assert all(cb.isChecked() for cb in w.tail_cb.values())              # o exemplo escolhe a cauda em E&C
    w.tail_cb["sem cauda"].setChecked(False)
    assert not w.controls_cb.isChecked()                                    # comandos: desligado por padrão
    w.controls_cb.setChecked(True)
    assert w.init_cb.currentData() == "uniforme" and w.starts_sb.value() == 1    # E&C: início e partidas de sempre
    w.init_cb.setCurrentIndex(w.init_cb.findData("lhs"))
    w.starts_sb.setValue(3)
    w.set_method("voa", "diagnóstico")                                      # os métodos guiados pela falha
    assert w.method["voa"].currentText() == "diagnóstico da falha (bandido)"
    assert w.rot.window() is w.menus["restrições"] and w.evals.window() is w.menus["configuração"]
    assert set(w.method) == {"configurações", "voa", "superfícies", "decolagem"}
    titles = [b.title() for b in w.menus["configuração"].findChildren(QtWidgets.QGroupBox)]
    assert "geometria" not in titles and not any(t[:1].isdigit() for t in titles)   # sem numeração nem caixa vazia
    w.rot.setValue(9.0)
    w.one_piece.setChecked(True)
    w.stab.setChecked(True)
    w.stab_level.setCurrentIndex(2)
    w.set_method("superfícies", "gerações")
    w.set_method("configurações", "todas")
    for c, cb in w.cat_cb.items():
        cb.setChecked(c == "monoplano")
    w.sens_method.setCurrentIndex(w.sens_method.findData("morris"))   # a sensibilidade: método e limites
    w.sens_traj.setValue(9)
    w.sens_limits.setChecked(True)
    assert w.method["superfícies"].currentText() == "gerações"        # o menu mostra só o nome do método
    out = w.read_problem()
    assert out.params["sensibilidade"]["método"] == "morris" and out.params["sensibilidade"]["limites"]
    assert out.params["geometria"]["rotação"] == 9.0 and out.params["geometria"]["uma_peça"]
    assert out.params["etapas"]["superfícies"] == "gerações" and out.params["categorias"] == ["monoplano"]
    g = w.geometry_params()
    assert g.rotation == 9.0 and g.connected and g.prop_clearance == pytest.approx(0.02)
    aeroopt.save(out, str(tmp_path / "x.opt.json"))
    w2 = AeroOptWindow(p, aeroopt.load(str(tmp_path / "x.opt.json")))
    assert w2.rot.value() == 9.0 and w2.methods()["superfícies"] == "gerações"
    assert w2.stab.isChecked() and w2.stab_level.currentData() == 3 and "nível 3" in w2.summary["restrições"].text()
    assert w2.methods()["configurações"] == "todas" and not w2.cat_cb["biplano"].isChecked()
    assert "9°" in w2.summary["restrições"].text() and "todas" in w2.summary["configuração"].text()
    sp = w2.sens_params()
    assert sp.method == "morris" and sp.trajectories == 9 and sp.limits and "Morris" in w2.summary["configuração"].text()
    assert "aviões: monoplano" in w2.summary["configuração"].text() and not w2.tail_cb["sem cauda"].isChecked()
    assert w2.read_problem().params["etapas"]["caudas"] == ["convencional", "em H", "em V"]
    assert "escolhe a cauda" in w2.summary["configuração"].text()
    assert w2.controls_cb.isChecked() and "ajusta os comandos" in w2.summary["configuração"].text()
    assert w2.init_cb.currentData() == "lhs" and w2.starts_sb.value() == 3 and w2.methods()["voa"] == "diagnóstico"
    assert "hipercubo latino, 3 partidas" in w2.summary["configuração"].text()
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
    w.select(best["name"])                                        # só a sensibilidade, do avião selecionado
    w.sens_method.setCurrentIndex(w.sens_method.findData("eixos"))
    assert w.sens_b.isEnabled()
    w.run_sensitivity()
    title = f"Sensibilidade nº {best.get('index', '')}"
    _wait(app, lambda: not w._side and any(w.best_tabs.tabText(i) == title for i in range(w.best_tabs.count())), 60)
    assert w.best_tabs.tabText(w.best_tabs.currentIndex()) == title and w.sens_b.isEnabled()


def test_sensitivity_tab_with_morris_and_limits(app):
    """a aba Sensibilidade desenha qualquer método e os limites do problema no mesmo tornado"""
    import copy as _copy

    from aeroopt import synthetic as sy
    from aeroopt.gui import AeroOptWindow, example_project
    from aeroopt.problem import apply_to_project, fold_bounds
    from aeroopt.sensitivity import SensParams, sensitivity
    p, pr = example_project()
    ev = sy.SyntheticEvaluator(p, evals=16)
    it = next(i for i in sy.sg.configurations(p, pr) if i.name == sy.best(p, pr))
    pp, prr = _copy.deepcopy(p), _copy.deepcopy(pr)
    fold_bounds(prr, pp)
    apply_to_project(prr, pp)
    {s.name: s for s in ev.stages(pp, prr)}["superfícies"].one(it)
    w = AeroOptWindow(p, pr, synthetic=True)
    for m in ("local", "morris"):
        res = sensitivity(p, pr, sy.sg.row(it), ev, SensParams(method=m, limits=True))
        body = w._sens_widget(res)
        txt = body.findChild(QtWidgets.QLabel).text()
        assert "limite pista" in txt and ("μ*" in txt) == (m == "morris")


def test_numbers_have_no_text_and_every_option_has_help(app):
    """os campos de número são só o número (a unidade fica no nome), e cada opção dos menus tem o "(?)" com a
    explicação; um problema gravado com os nomes antigos mostra e marca esses nomes, e só eles"""
    from aeroopt.gui import AeroOptWindow, _Help, example_project
    p, pr = example_project()
    pr.params["categorias"] = ["asa baixa", "parasol", "biplano"]
    w = AeroOptWindow(p, pr)
    for k in ("restrições", "configuração"):
        for s in w.menus[k].findChildren(QtWidgets.QAbstractSpinBox):
            assert s.suffix() == "" and s.prefix() == ""
        helps = w.menus[k].findChildren(_Help)
        assert helps and all(h.toolTip() for h in helps)
    assert len(w.menus["configuração"].findChildren(_Help)) >= 15
    assert [c for c, cb in w.cat_cb.items() if cb.isChecked()] == ["biplano", "asa baixa", "parasol"]
    assert not w.cat_row["parasol"].isHidden() and w.cat_row["asa média"].isHidden()
    assert w.read_problem().params["categorias"] == ["biplano", "asa baixa", "parasol"]


def test_menus_scroll_and_the_regulation_stays_on_top(app):
    """num notebook de 1366 × 768 o .toml do regulamento é mais alto que a tela: o corpo dos submenus rola, e o
    combo do regulamento e o OK ficam sempre à vista (antes o submenu crescia até o conteúdo e os dois sumiam)"""
    from aeroopt.gui import AeroOptWindow, example_project
    p, pr = example_project()
    w = AeroOptWindow(p, pr)
    m = w.menus["pontuação"]
    sa = m.findChild(QtWidgets.QScrollArea)
    assert sa is not None and sa.widget() is w.scoring
    assert not w.scoring.isAncestorOf(w.scoring.combo) and m.isAncestorOf(w.scoring.combo)
    assert all(mm.findChild(QtWidgets.QScrollArea) is not None for mm in w.menus.values())
    w.scoring.combo.setCurrentText("sae_br_2026_regular")
    m.accept()
    w.problem = w.read_problem()
    assert w.problem.scoring == "sae_br_2026_regular"
