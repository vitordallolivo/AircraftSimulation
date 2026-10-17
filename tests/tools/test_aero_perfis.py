"""tools/aero: os perfis de teste montam e os métodos do núcleo dão os números esperados"""
from __future__ import annotations

import math

import pytest

from tools.aero.casos import CASOS
from tools.aero.coeficientes import rodar, tabela

NUCLEO = {"nucleo", "nucleo_solo25", "nucleo_solo10", "nucleo_llt"}


@pytest.fixture(scope="module")
def ret_ar8(backend):
    return {r["metodo"]: r for r in rodar(backend, CASOS["ret_ar8"](), 12.0, NUCLEO)}


def test_casos_montam():
    for k, f in CASOS.items():
        ac = f()
        assert ac.fuselage.enabled is False and ac.propulsion == [], k


def test_momentos_no_quarto_da_cma(ret_ar8):
    # asa retangular sem enflechamento: o 1/4 da CMA é o centro aerodinâmico, C_mα ≈ 0
    for r in ret_ar8.values():
        assert abs(r["resumo"]["Cma"]) < 1e-3, r["metodo"]


def test_solo_mccormick_so_no_induzido(ret_ar8):
    # McCormick: φ = (16 h/b)² / (1 + (16 h/b)²) no arrasto induzido; h/b = 0,25 → 16/17, h/b = 0,1 → 2,56/3,56
    k0 = ret_ar8["nucleo"]["resumo"]["k"]
    assert ret_ar8["nucleo_solo25"]["resumo"]["k"] == pytest.approx(k0 * 16 / 17, rel=2e-3)
    assert ret_ar8["nucleo_solo10"]["resumo"]["k"] == pytest.approx(k0 * 2.56 / 3.56, rel=2e-3)
    for m in ("nucleo_solo25", "nucleo_solo10"):
        assert ret_ar8[m]["resumo"]["CLa"] == pytest.approx(ret_ar8["nucleo"]["resumo"]["CLa"], rel=1e-9)


def test_tabela(ret_ar8):
    txt = tabela("ret_ar8", list(ret_ar8.values()), 12.0)
    assert "nucleo_llt" in txt and all(math.isfinite(r["resumo"]["CLa"]) for r in ret_ar8.values())


def test_distancia_contra_referencia():
    from types import SimpleNamespace

    from tools.aero.coeficientes import distancia
    pol = SimpleNamespace(derivs={"Clp": -0.5})
    ref = dict(metodo="ref", polar=pol, resumo=dict(CLa=5.0, Cma=0.0, CL0=0.2))
    met = dict(metodo="m", polar=SimpleNamespace(derivs={"Clp": -0.6}), resumo=dict(CLa=5.5, Cma=-0.5, CL0=0.2))
    d = distancia([ref, met], ref)["m"]
    assert d["CLa"] == pytest.approx(10.0)
    assert d["Cma"] == pytest.approx(10.0)       # ΔC_mα / C_Lα = −0,5/5: ponto neutro 10 % da CMA atrás
    assert d["Clp"] == pytest.approx(-20.0)


def test_so_e_perfil(tmp_path):
    from aerosim.model.airfoil import naca4, write_dat
    from tools.aero.casos import com_perfil, so
    ac = CASOS["convencional"]()
    ev = so(ac, ["ev"])
    assert [s.role for s in ev.surfaces] == ["vtail"] and ev.Sref == ac.Sref
    assert so(CASOS["ret_ar8"](), ["ev"]) is None
    write_dat(str(tmp_path / "p.dat"), "NACA 4415", naca4("4415"))
    a = com_perfil(ac, str(tmp_path / "p.dat"))
    assert a.surfaces[0].airfoil.name == "NACA 4415" and a.surfaces[1].airfoil.name != "NACA 4415"


def test_varredura_paineis(backend):
    from tools.aero.coeficientes import varrer
    res = varrer(backend, {"ret_ar8": CASOS["ret_ar8"]()}, "paineis", [2, 8], {"nucleo_fino"})
    clp = [v["Clp"] for v in res[("ret_ar8", "nucleo_fino")]]
    # faixas com C_Lα uniforme: o C_lp tende ao da teoria das faixas, −C_Lα/6 na asa retangular
    cla = res[("ret_ar8", "nucleo_fino")][1]["CLa"]
    assert abs(clp[1] + cla / 6) < abs(clp[0] + cla / 6) and clp[1] == pytest.approx(-cla / 6, rel=0.01)


# MachUpX (Goates e Hunsaker 2021, implementação dos autores: github.com/usuaero/MachUpX), 80 painéis por semiasa,
# perfil linear a = 5,9/rad e α0 = −2,1147° (o NACA 2412 do programa), α = 2°, V = 12 m/s; trapézio com o 1/4 de
# corda a −2,39° e enflechada a 22,99° (os mesmos de casos.py)
MACHUPX = {"ret_ar8": (4.5997, 0.01249), "diedro": (4.56792, -0.08379), "trapezio": (4.69971, 0.01925),
           "enflechada": (4.53935, -0.0333)}


@pytest.mark.parametrize("caso", list(MACHUPX))
def test_goates_hunsaker_contra_machupx(backend, caso):
    rows = {r["metodo"]: r for r in rodar(backend, CASOS[caso](), 12.0, {"nucleo_gh"})}
    v = {**rows["nucleo_gh"]["resumo"], **rows["nucleo_gh"]["polar"].derivs}
    CLa, Clb = MACHUPX[caso]
    assert v["CLa"] == pytest.approx(CLa, rel=0.015)
    assert v["Clb"] == pytest.approx(Clb, rel=0.03)


def test_decolagem_replay_bate_com_o_registro(backend):
    # o núcleo reavaliado no estado de cada ponto (altura, tração, CG do registro) dá o C_L que a simulação usou
    import numpy as np
    from aerosim.model.templates import conventional
    from tools.aero.decolagem import avaliar, decolar, erros, pontos
    ac = conventional()
    res, log = decolar(backend, ac)
    assert res.status == "COMPLETED" and "n_LO" in res.summary
    idx = pontos(log, 6, 4.0)
    res = avaliar(backend, ac, log, idx, {"nucleo_gh"})
    assert np.nanmax(np.abs(res["simulacao"]["CL"] - log["CL"][idx])) < 1e-6
    e = erros(res)["nucleo_gh"]
    assert all(np.isfinite(e[k][0]) for k in ("CL", "CD", "Cm"))


def test_modelo_do_voo_padrao_e_as_faixas():
    # "faixas" não escreve nada nos Params: o núcleo fica no de sempre (o AeroDrive monta os Params com os padrões)
    from aerosim.backend.zig.translator import aero_native
    from aerosim.model.aircraft import SimSettings
    s = SimSettings()
    assert s.aero_model == "faixas" and aero_native(s) == {}
    s.aero_model = "llt_gh"
    assert aero_native(s)["aero_model"] == 1 and aero_native(s)["llt_joint"] > 0
    s.aero_model = "xyz"
    with pytest.raises(ValueError):
        aero_native(s)


def test_tabela_das_faixas_decola_como_as_faixas(backend):
    # a tabela feita do próprio núcleo (sem efeito solo nem esteira, derivadas lineares) sai do chão a menos de 5 % da
    # distância das faixas: o caminho da tabela (flight_table → tradutor → aerotable.zig) está certo
    from aerosim.model.templates import conventional
    from tools.aero.missao import voar
    v = voar(backend, conventional(), ["faixas", "tabela:zig"], "decolagem")
    a, b = v["faixas"]["res"].summary, v["tabela:zig"]["res"].summary
    assert v["tabela:zig"]["res"].status == "COMPLETED"
    assert b["n_LO"] == pytest.approx(a["n_LO"], rel=0.05)
    assert b["V_LO"] == pytest.approx(a["V_LO"], rel=0.03)


def test_erro_do_percurso():
    # contra si mesmo: zero; o percurso é simétrico; um voo só atrasado não desvia do caminho (o RMS no tempo, sim)
    import numpy as np
    from types import SimpleNamespace
    from tools.aero.missao import ESTADOS, desvio_percurso, erros
    def voo(atraso=0.0, dh=0.0):
        tt = np.linspace(0, 10 + atraso, 501)          # o atrasado voa o mesmo caminho até o fim
        s = np.clip(tt - atraso, 0, None)
        log = dict(t=tt, n=10 * s, e=0 * s, h=0.5 * s + dh, **{k: 0 * s for k, _, _ in ESTADOS if k != "h"})
        return dict(res=SimpleNamespace(status="COMPLETED", summary={}), log=log)

    voos = dict(ref=voo(), igual=voo(), atrasado=voo(atraso=1.0), acima=voo(dh=2.0))
    e = erros(voos, "ref")
    assert e["igual"]["perc_rms"] == 0 and e["igual"]["h"] == 0
    assert e["atrasado"]["perc_med"] < 0.05 and e["atrasado"]["h"] > 0.3
    assert e["acima"]["perc_med"] > 1.5
    a, b = voos["ref"]["log"], voos["acima"]["log"]
    assert np.allclose(np.sort(desvio_percurso(a, b)), np.sort(desvio_percurso(b, a)))
