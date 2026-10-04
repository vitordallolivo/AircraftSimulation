"""GUI: monta a janela sem tela (offscreen), edita, arrasta e roda uma simulação pela aba."""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
QtWidgets = pytest.importorskip("PyQt6.QtWidgets")


@pytest.fixture(scope="module")
def app():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def pump(app, t=0.2):
    end = time.time() + t
    while time.time() < end:
        app.processEvents()
        time.sleep(0.005)


def test_window_tabs_and_edit(app, manager):
    from aerosim.gui.main_window import MainWindow
    from aerosim.gui.state import AppState
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    w = MainWindow(st)
    w.show()
    pump(app)
    titles = [w.tabs.tabText(i) for i in range(w.tabs.count())]
    assert titles[-1] == "Montagem" and "Missão" in titles and "Desempenho" in titles
    assert "Decolagem" not in titles and "Polar" not in titles      # viraram modos/partes de outras abas
    cfg = w.config
    n0 = len(st.aircraft.propulsion)
    cfg._add_motor()
    cfg._add_tank()
    assert len(st.aircraft.propulsion) == n0 + 1 and len(st.aircraft.tanks) == 2
    cfg._rotate_wind(15)
    assert st.aircraft.environment.wind_from == 45
    cfg._on_pick("boom")                                  # liga o tubo pelo editor da direita
    cfg.form.widgets["enabled"].setChecked(True)
    assert st.aircraft.boom.enabled
    cfg._on_pick("gear")                                  # tipo do trem também só pelo editor
    cfg.form.widgets["layout"].findChild(QtWidgets.QComboBox).setCurrentText("conventional")
    g = st.aircraft.gear
    assert g.layout == "conventional" and g.steer_x < g.main_x
    pump(app, 0.7)
    st.undo()                                             # Ctrl-Z volta o trem
    assert st.aircraft.gear.layout == "tricycle"
    st.redo()
    assert st.aircraft.gear.layout == "conventional"
    pump(app, 0.5)
    txt = cfg.summary.toPlainText()
    assert "margem" in txt and "Pista" in txt and "T/W" in txt
    cfg.restore()                                         # volta ao que foi aberto
    pump(app, 0.3)
    assert len(st.aircraft.propulsion) == n0 and len(st.aircraft.tanks) == 1


def test_simulation_tab_runs(app, manager):
    from aerosim.gui.state import AppState
    from aerosim.gui.tabs.simulation_tab import SimulationTab
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    tab = SimulationTab(st, manager.get("mission"))
    tab.inputs["mode"].setCurrentText("só decolagem")
    pump(app, 0.1)
    tab.reconfigure()
    assert "x_warning" in tab.inputs and "start" not in tab.inputs   # o formulário mudou com o modo
    tab.start()
    t0 = time.time()
    while tab._thread is not None and time.time() - t0 < 60:
        pump(app, 0.05)
    assert tab.result is not None and tab.result.status == "COMPLETED"
    assert tab.table.rowCount() > 5


def test_propulsion_poly_editor(app, manager, desempenho_xlsx, mapping_path):
    """importar a planilha traz os conjuntos de tração; o editor troca motor <-> polinômio"""
    from PyQt6 import QtCore
    from aerosim.data.cellmap import CellMapAircraftSource
    from aerosim.gui.main_window import MainWindow
    from aerosim.gui.state import AppState
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    st = AppState(manager, ac)
    st.catalog = st.catalog.merge(src.catalog)
    w = MainWindow(st)
    cfg = w.config
    for i in range(cfg.comp_list.count()):
        if cfg.comp_list.item(i).data(QtCore.Qt.ItemDataRole.UserRole) == "prop:0":
            cfg.comp_list.setCurrentRow(i)
    pump(app)
    combos = cfg.editor_area.widget().findChildren(QtWidgets.QComboBox)
    model = next(c for c in combos if c.count() == 2 and "polinômio" in c.itemText(1))
    assert model.currentIndex() == 1
    sets = next(c for c in combos if c.findText("conjunto A") >= 0)
    sets.setCurrentText("conjunto A")
    assert st.aircraft.propulsion[0].thrust_poly.name == "conjunto A"
    model.setCurrentIndex(0)
    assert st.aircraft.propulsion[0].thrust_model == "motor"


def test_envelope_export_xlsx(app, manager, tmp_path, desempenho_xlsx, mapping_path):
    """o envelope sai em Excel (como o Envelope.xlsx do original): uma aba por tabela"""
    from openpyxl import load_workbook
    from aerosim.data.cellmap import CellMapAircraftSource
    from aerosim.gui.tabs.simulation_tab import export_result
    ac = CellMapAircraftSource(mapping_path).load(desempenho_xlsx)
    res = manager.run("envelope", ac, {"method": "planilha", "table": False})
    out = str(tmp_path / "Envelope.xlsx")
    export_result(res, out)
    wb = load_workbook(out)
    sh = wb["envelope_planilha"]
    head = [c.value for c in sh[1]]
    assert head[:7] == ["h", "rho", "Vmin", "Vmax", "Ve", "Vman", "Vcru"]
    assert sh.max_row == len(res.series["envelope_planilha"]["h"]) + 1
    assert "resumo" in wb.sheetnames


def test_stability_and_aero_tabs(app, manager):
    from aerosim.gui.state import AppState
    from aerosim.gui.tabs.simulation_tab import SimulationTab
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    for name, over in (("stability", {"size_tail": False}), ("aerodynamics", {"use_lltdrek": False})):
        tab = SimulationTab(st, manager.get(name))
        for k, v in over.items():
            tab.inputs[k].setChecked(v)
        tab.start()
        t0 = time.time()
        while tab._thread is not None and time.time() - t0 < 120:
            pump(app, 0.05)
        assert tab.result is not None, tab.msg.text()
        assert tab.table.rowCount() > 3 and tab.diag.rowCount() >= 3
    # a aba se refaz quando a configuração muda (tirar a EH tira a área de EH)
    tab = SimulationTab(st, manager.get("stability"))
    assert "size_tail" in tab.inputs
    st.aircraft.surfaces = [s for s in st.aircraft.surfaces if s.role != "htail"]
    st.notify("geometry")
    tab.reconfigure()
    assert "size_tail" not in tab.inputs


def test_undo_restores_tab_values(app, manager):
    """Ctrl+Z também volta o que se escolheu nos formulários e tabelas das abas"""
    from aerosim.gui.state import AppState
    from aerosim.gui.tabs.simulation_tab import SimulationTab
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    tab = SimulationTab(st, manager.get("mission"))
    tab.inputs["mode"].setCurrentText("só decolagem")
    pump(app, 0.1)
    assert "start" not in tab.inputs
    assert st.undo()
    pump(app, 0.1)
    assert tab.inputs["mode"].currentText() == "missão" and "start" in tab.inputs
    assert st.redo()
    pump(app, 0.1)
    assert tab.inputs["mode"].currentText() == "só decolagem"


def test_sprint_stages_from_scratch_to_assembly(app, manager, tmp_path, monkeypatch):
    """Perfil → Asa → Empenagem → Motores: cada etapa guarda e a última manda o avião para a Montagem"""
    monkeypatch.setenv("AEROSIM_PROJETOS", str(tmp_path))
    from aerosim.gui.main_window import MainWindow
    from aerosim.gui.state import AppState
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    w = MainWindow(st)
    w.show()
    titles = [w.tabs.tabText(i) for i in range(w.tabs.count())]
    assert titles.index("Aerodinâmica") < titles.index("Estabilidade") < titles.index("Desempenho") < titles.index("Missão")
    aero = w.tabs.widget(titles.index("Aerodinâmica"))
    assert [aero.tabText(i) for i in range(aero.count())] == ["Perfil", "Asa", "Avião montado"]
    w.tabs.setCurrentWidget(aero)
    perfil = aero.widget(0)
    pump(app, 0.6)
    assert perfil.checks.table.rowCount() > 3              # a polar de cada candidato
    perfil._keep()                                         # "Usar na asa" vai para a etapa Asa
    assert aero.currentIndex() == 1
    asa = aero.widget(1)
    asa.form.widgets["area"].setValue(1.0)
    asa.form.widgets["area"].valueChanged.emit(1.0)
    pump(app, 0.6)
    assert st.design.wing_draft.area == 1.0 and asa.checks.diag.rowCount() >= 3
    asa._keep()
    assert [x.name for x in st.design.wings] == ["asa 1"]
    est = w.tabs.widget(titles.index("Estabilidade"))
    w.tabs.setCurrentWidget(est)
    pump(app, 0.5)
    est.widget(0)._keep()
    assert st.design.sets[0].wing.name == "asa 1"
    des = w.tabs.widget(titles.index("Desempenho"))
    w.tabs.setCurrentWidget(des)
    pump(app, 1.0)
    motores = des.widget(0)
    assert motores.ac is not None and motores.checks.diag.rowCount() >= 3
    assert [des.tabText(i) for i in range(des.count())] == ["Motores e montagem", "Estudo e ponto de projeto",
                                                            "Avião montado"]
    estudo = des.widget(1)                                 # retroalimentação: ponto de projeto acoplado
    st.design.study.n, st.design.study.places = 2, "A=600"
    estudo.start()
    t0 = time.time()
    while estudo._thread is not None and time.time() - t0 < 120:
        pump(app, 0.1)
    assert len(estudo.rows) == 2 and estudo.table.rowCount() == 2
    n = len(st.fleet)
    motores.send()
    assert len(st.fleet) == n + 1 and w.tabs.currentWidget() is w.config
    assert st.aircraft.name.startswith("avião 1") and st.path and os.path.exists(st.path)
    pump(app, 1.2)
    assert os.path.exists(st.design_path)                 # o projeto da sprint se grava sozinho
