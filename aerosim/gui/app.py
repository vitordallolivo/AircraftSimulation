"""Ponto de entrada da GUI:  python -m aerosim.gui [aeronave.cfg|.json|.xlsx | projeto.json]

Sem arquivo: volta ao último projeto (etapas, estudos e Montagem); sem nada guardado, a Montagem começa vazia.
Com um projeto .json: abre ele e volta de onde parou. Com um avião: ele vai para a Montagem."""
from __future__ import annotations

import sys


def _show_error(kind, value, tb) -> None:
    """erro não tratado num botão ou sinal: o PyQt6 fecharia a GUI (abort); aqui vira um aviso e o trabalho continua.
    O rastro completo sai no terminal, para relatar"""
    import traceback

    from PyQt6 import QtWidgets
    traceback.print_exception(kind, value, tb)
    if issubclass(kind, KeyboardInterrupt):
        QtWidgets.QApplication.quit()
        return
    box = QtWidgets.QMessageBox(QtWidgets.QMessageBox.Icon.Warning, "Erro",
                                f"{kind.__name__}: {value}\n\nA GUI continua aberta; o rastro completo está no terminal.")
    box.setDetailedText("".join(traceback.format_exception(kind, value, tb)))
    box.exec()


def main(argv: list[str] | None = None) -> int:
    from PyQt6 import QtWidgets

    from aerosim.data import load_aircraft
    from aerosim.manager import SimulationManager
    from aerosim.model.templates import empty

    from .main_window import MainWindow
    from .state import AppState

    argv = sys.argv if argv is None else argv
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(argv)
    sys.excepthook = _show_error
    from aerosim.design.store import is_sprint_path
    ac, path = empty(), None
    project = len(argv) > 1 and is_sprint_path(argv[1])
    if len(argv) > 1 and not project:
        ac, path = load_aircraft(argv[1]), argv[1]
    from PyQt6 import QtCore
    from aerosim.data.projects import JsonProjectStore, default_root
    settings = QtCore.QSettings("aerosim", "aerosim")
    root = settings.value("projects_root", default_root())
    sprint = settings.value("sprint_dir", "") or None          # a pasta da sprint escolhida da última vez
    state = AppState(SimulationManager(), ac, projects=JsonProjectStore(str(root)), design_dir=sprint)
    state.path = path
    win = MainWindow(state)
    if project:
        win.open_path(argv[1], quiet=True)
    elif path is None and (state.design.fleet or state.design.ui):
        state.open_design(state.design)             # continua de onde parou
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
