"""python -m aeroopt [projeto.json] [problema.opt.json] [--exemplo]: abre a janela do aeroopt (`aeroopt/gui.py`)."""
import sys

if __name__ == "__main__":
    from .gui import main
    sys.exit(main())
