"""Ponto de entrada da GUI:  python -m aerosim.gui [aeronave.cfg|.json|.xlsx]"""
from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    from PyQt6 import QtWidgets

    from aerosim.data import load_aircraft
    from aerosim.manager import SimulationManager
    from aerosim.model.templates import conventional

    from .main_window import MainWindow
    from .state import AppState

    argv = sys.argv if argv is None else argv
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(argv)
    ac, path = conventional(), None
    if len(argv) > 1:
        ac, path = load_aircraft(argv[1]), argv[1]
    state = AppState(SimulationManager(), ac)
    state.path = path
    win = MainWindow(state)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
