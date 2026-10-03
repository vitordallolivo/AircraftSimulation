"""Biblioteca "meus aviões" (IProjectStore em JSON)."""
from aerosim.data import JsonProjectStore, load_aircraft
from aerosim.model.aircraft import WingDevice
from aerosim.model.templates import conventional, flying_wing


def test_save_list_load_delete(tmp_path):
    st = JsonProjectStore(str(tmp_path / "meus"))
    a = flying_wing()
    a.wing.devices.append(WingDevice("placa", height=0.1))
    i1 = st.save(a, "Asa X — versão 1")
    i2 = st.save(conventional(), "Treinador")
    assert {p.name for p in st.list()} == {"Asa X — versão 1", "Treinador"}
    b = st.load("Asa X — versão 1")
    assert b.name == "Asa X — versão 1" and b.wing.devices[0].kind == "placa"
    assert b.wing.airfoil.coords           # perfil dentro do arquivo
    assert load_aircraft(i1.path).name == "Asa X — versão 1"      # também abre por Arquivo → Abrir
    st.save(conventional(), "Treinador")    # mesmo nome: atualiza, não duplica
    assert len(st.list()) == 2
    st.delete("Treinador")
    assert [p.name for p in st.list()] == ["Asa X — versão 1"]
    assert i2.summary.startswith("S =")
