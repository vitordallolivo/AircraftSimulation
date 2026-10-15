"""Fixtures comuns. Os testes estão separados por camada (uma pasta cada):

    tests/core     núcleo Zig: testes unitários por grupo, LUTs, ABI, sessão, tração polinomial, C original
    tests/model    modelo de dados: perfis, geometria, massa, compilação para o núcleo
    tests/data     Aircraft Data: .json/.cfg/.xlsx, catálogo, planilha por mapa de células
    tests/manager  Simulation Manager: simulações, checkpoints, troca do backend
    tests/gui      GUI sem tela (offscreen)

    pytest tests/core            uma camada
    pytest -m lut                só as LUTs
    pytest -m bench              medições de tempo (fora da execução padrão)
"""
import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "helpers"))


@pytest.fixture(scope="session")
def backend():
    from aerosim.backend.zig import ZigBackend
    return ZigBackend()


@pytest.fixture(scope="session")
def manager(backend):
    from aerosim.manager import SimulationManager
    return SimulationManager(backend)


@pytest.fixture
def desempenho_xlsx(tmp_path):
    """planilha no formato Dados_Desempenho.xlsx (Geral, Superficies, Tracao)"""
    from sheet_fixtures import write_desempenho
    p = str(tmp_path / "Dados_Desempenho.xlsx")
    write_desempenho(p)
    return p


@pytest.fixture
def mapping_path():
    return os.path.join(ROOT, "data", "mappings", "dados_desempenho.json")


@pytest.fixture(autouse=True)
def _save_check_accepts(monkeypatch):
    """a pergunta 'salvar mesmo assim?' (lista de verificação) responde sim nos testes; quem quiser testar a
    resposta troca `confirm_save` de novo. As chamadas ficam em `calls`"""
    calls = []
    try:
        from aerosim.gui.widgets import save_check
    except Exception:                       # sem PyQt
        yield calls
        return

    def fake(parent, ac, project=None):
        calls.append((ac.name, save_check.ck.aircraft_checklist(ac, project)))
        return True
    monkeypatch.setattr(save_check, "confirm_save", fake)
    yield calls
