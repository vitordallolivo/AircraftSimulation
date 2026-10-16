"""T58: métodos de carga atrás da interface (aerosim/interfaces/loads.py: ILoadMethod, LoadPoint). O registro, o mesmo
ponto de voo para todos os métodos, a saída padrão (LoadResult) e o que cada método não modela."""
import numpy as np

from aerosim.aero import all_load_methods, load_method
from aerosim.aero.span_loads import LoadCase, prepare
from aerosim.interfaces.loads import SUPPORTS, ILoadMethod, LoadResult
from aerosim.model.templates import conventional, flying_wing
from aerosim.model.universal import build_model


def test_registry(backend):
    ms = all_load_methods(backend)
    names = [m.name for m in ms]
    assert len(set(names)) == len(names) and {"llt", "faixas", "vlm_asb"} <= set(names)
    for m in ms:
        assert isinstance(m, ILoadMethod) and m.title and m.source
        assert m.supports <= set(SUPPORTS)
    assert load_method(backend, "VLM do AeroSandbox").name == "vlm_asb"


def test_every_method_on_the_same_point(backend):
    """o ponto (trimagem e hélices) sai uma vez; cada método devolve um LoadResult com a asa sustentando, a fonte e o
    mesmo α. Os números diferem por método (o VLM resolve a corda; a linha sustentadora não)"""
    for tpl in (conventional, flying_wing):
        ac = tpl()
        pt = prepare(backend, ac, LoadCase(V=12, props=False))
        model = build_model(ac)
        for m in all_load_methods(backend):
            if m.available():
                continue
            res = m.compute(model, pt)
            assert isinstance(res, LoadResult)
            wing = res.by_role("wing")[0]
            assert np.all(np.isfinite(wing.fields["L"]))
            assert 0.5 * pt.weight < wing.integral("L") < 1.5 * pt.weight, (tpl.__name__, m.name)
            assert res.meta["fonte"] == m.source and res.meta["alpha"] == pt.alpha


def test_what_each_method_does_not_model(backend):
    assert load_method(backend, "vlm_asb").missing(["esteira"]) == [SUPPORTS["esteira"]]
    assert load_method(backend, "llt").missing(["esteira", "comandos"]) == []
    assert "estol" in load_method(backend, "faixas").supports


def test_loads_tab_compares_two_methods(manager):
    ac = conventional()
    r = manager.run("loads", ac, {"V": 12.0, "helice": "sem hélice", "method": "linha sustentadora (Phillips e Snyder)",
                                  "compare": "VLM do AeroSandbox"})
    keys = [k for k in r.series if k.startswith("L_wing_")]
    assert any("linha sustentadora" in k for k in keys) and any("VLM do AeroSandbox" in k for k in keys)
    a1 = r.summary["[sem hélice · linha sustentadora (Phillips e Snyder)] α (°), profundor (°)"]
    a2 = r.summary["[sem hélice · VLM do AeroSandbox] α (°), profundor (°)"]
    assert a1 == a2                                           # o mesmo ponto de voo
