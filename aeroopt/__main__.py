"""python -m aeroopt [projeto.json] [problema.opt.json] [--exemplo] [--sintetico]: abre a janela do aeroopt
(`aeroopt/gui.py`). `--sintetico` roda com os dados de teste (`aeroopt/synthetic.py`): rápido e com o resultado sabido."""
import sys

if __name__ == "__main__":
    from .gui import main
    sys.exit(main())
