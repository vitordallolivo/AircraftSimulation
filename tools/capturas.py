"""Fotos de todas as abas (roda cada simulação com os padrões).

    xvfb-run -a python tools/capturas.py saida/ [nome da aba ...]     # Linux sem tela (com o 3D)
    python tools/capturas.py saida/                                   # com tela
"""
import os
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
if not os.environ.get("DISPLAY"):           # sem tela: sem o 3D
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PyQt6 import QtWidgets, QtCore
app = QtWidgets.QApplication(sys.argv)
from aerosim.manager import SimulationManager
from aerosim.gui.state import AppState
from aerosim.gui.main_window import MainWindow, ProjectsDialog
from aerosim.data.projects import JsonProjectStore
from aerosim.model.templates import conventional, flying_wing
from aerosim.model.aircraft import WingDevice
OUT = sys.argv[1] if len(sys.argv) > 1 else "capturas"
os.makedirs(OUT, exist_ok=True)
def pump(t=0.3):
    e = time.time() + t
    while time.time() < e:
        app.processEvents(); time.sleep(0.01)
ac = conventional(); ac.name = "Treinador com winglet"
ac.wing.devices.append(WingDevice("winglet", height=0.18, cant=15, sweep=35))
store = JsonProjectStore(os.path.join(OUT, "meus_avioes"))
store.save(flying_wing(), "Asa voadora 2 m"); store.save(conventional(), "Treinador original")
st = AppState(SimulationManager(), ac, projects=store)
win = MainWindow(st); win.resize(1800, 1100); win.show(); pump(1.0)
win.grab().save(os.path.join(OUT, "00_configuracao.png"))
cfg = win.config
for i in range(cfg.comp_list.count()):
    if cfg.comp_list.item(i).data(QtCore.Qt.ItemDataRole.UserRole) == "surface:0":
        cfg.comp_list.setCurrentRow(i); break
pump(0.8)
win.grab().save(os.path.join(OUT, "01_configuracao_asa_dispositivos.png"))
sa = cfg.editor_area
sa.verticalScrollBar().setValue(sa.verticalScrollBar().maximum()); pump(0.4)
win.grab().save(os.path.join(OUT, "02_configuracao_asa_dispositivos_fim.png"))
d = ProjectsDialog(st, win); d.resize(1000, 400); d.show(); pump(0.4)
d.grab().save(os.path.join(OUT, "03_meus_avioes.png")); d.close()
# "Missão" roda a missão; "Missão=só decolagem" escolhe o modo antes (campo 'mode' da aba)
only = [a.split("=", 1) for a in sys.argv[2:]] or None
runs = []
for k in range(1, win.tabs.count()):
    name = win.tabs.tabText(k)
    if only is None:
        runs.append((k, name, None))
    else:
        runs += [(k, name, o[1] if len(o) > 1 else None) for o in only if o[0] == name]
for k, name, mode in runs:
    tab = win.tabs.widget(k)
    win.tabs.setCurrentIndex(k); pump(0.3)
    if mode and "mode" in tab.inputs:
        tab.inputs["mode"].setCurrentText(mode); pump(0.2); tab.reconfigure(); pump(0.3)
    tab.start(); t0 = time.time()
    while tab._thread is not None and time.time() - t0 < 600:
        app.processEvents(); time.sleep(0.05)
    pump(0.8)
    fn = f"{k + 3:02d}_{name.replace(' ', '_').lower()}" + (f"_{mode.split(':')[0].split(' (')[0].replace(' ', '_')}" if mode else "")
    sb = tab.right_scroll.verticalScrollBar()
    page = max(tab.right_scroll.viewport().height() - 40, 200)
    pos, i = 0, 0
    while True:                                   # uma foto por "página" da rolagem
        sb.setValue(pos); pump(0.5)
        win.grab().save(os.path.join(OUT, f"{fn}_p{i:02d}.png"))
        if pos >= sb.maximum() or i >= 30:
            break
        pos, i = min(pos + page, sb.maximum()), i + 1
    print(name, mode or "", tab.msg.text()[:80], flush=True)
