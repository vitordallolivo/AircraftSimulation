"""Ponto de entrada da GUI:  python -m aerosim.gui [aeronave.cfg|.json|.xlsx | projeto.json]

Sem arquivo: volta ao último projeto (etapas, estudos e Montagem); sem nada guardado, a Montagem começa vazia.
Com um projeto .json: abre ele e volta de onde parou. Com um avião: ele vai para a Montagem."""
from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    from PyQt6 import QtWidgets

    from aerosim.data import load_aircraft
    from aerosim.manager import SimulationManager
    from aerosim.model.templates import empty

    from .main_window import MainWindow
    from .state import AppState

    argv = sys.argv if argv is None else argv
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(argv)
    from aerosim.design.project import is_project_file
    ac, path = empty(), None
    project = len(argv) > 1 and is_project_file(argv[1])
    if len(argv) > 1 and not project:
        ac, path = load_aircraft(argv[1]), argv[1]
    from PyQt6 import QtCore
    from aerosim.data.projects import JsonProjectStore, default_root
    root = QtCore.QSettings("aerosim", "aerosim").value("projects_root", default_root())
    state = AppState(SimulationManager(), ac, projects=JsonProjectStore(str(root)))
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
