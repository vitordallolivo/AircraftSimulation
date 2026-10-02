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
    assert titles[0] == "Configuração" and "Decolagem" in titles and "Envelope de voo" in titles
    cfg = w.config
    n0 = len(st.aircraft.propulsion)
    cfg._add_motor()
    cfg._add_tank()
    assert len(st.aircraft.propulsion) == n0 + 1 and len(st.aircraft.tanks) == 2
    cfg._rotate_wind(15)
    assert st.aircraft.environment.wind_from == 45
    cfg.chk_boom.setChecked(True)
    assert st.aircraft.boom.enabled
    pump(app, 0.5)
    assert "margem" in cfg.summary.text()


def test_simulation_tab_runs(app, manager):
    from aerosim.gui.state import AppState
    from aerosim.gui.tabs.simulation_tab import SimulationTab
    from aerosim.model.templates import conventional
    st = AppState(manager, conventional())
    tab = SimulationTab(st, manager.get("takeoff"))
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
