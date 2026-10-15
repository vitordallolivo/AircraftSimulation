"""Aba Missão: terreno (mesa/plataforma), x_warning/z_warning, otimização do acionamento do profundor,
missão por etapas (inclusive começar de uma etapa sem checkpoint), MTOW e o Desempenho por cálculo."""
import math

import numpy as np
import pytest

from aerosim.manager import SimulationManager
from aerosim.manager import takeoff_opt as TO
from aerosim.manager.runner import Runner, Stop
from aerosim.manager.simulations.mission import MODES
from aerosim.model.mission import takeoff_runway
from aerosim.model.templates import TEMPLATES


def _takeoff(backend, ac):
    with Runner(backend, ac, takeoff_runway(), dict(tmax=60, dtlog=0.01)) as r:
        r.start_ground()
        return r.run(Stop(takeoff=True), live=False)


def test_table_takeoff_starts_on_top_and_leaves_at_edge(backend):
    ac = TEMPLATES["conventional"]()
    ac.airfield.takeoff_from, ac.airfield.table_height, ac.airfield.table_length = "mesa", 1.5, 15.0
    o = _takeoff(backend, ac)
    assert o.log["hgnd"][0] == pytest.approx(1.5) and o.log["hw"][0] == pytest.approx(0.0, abs=1e-6)
    assert o.events["nLO"] == pytest.approx(15.0, abs=0.5)          # sai da mesa na borda
    n_dec, h_min, xe, zs, ok = TO.judge(o.log, o.events, 60.0, 0.0)
    assert h_min < 0 and zs == pytest.approx(-h_min) and not ok     # caiu abaixo da mesa: z_warning = 0 falha
    assert TO.judge(o.log, o.events, 60.0, -2.0)[4] or o.status.name != "COMPLETED"


def test_judge_x_and_z_on_ground(backend):
    o = _takeoff(backend, TEMPLATES["conventional"]())
    n_dec, h_min, xe, zs, ok = TO.judge(o.log, o.events, 80.0, 1.0)
    h = o.log["h"] - o.log["h"][0]
    assert n_dec == pytest.approx(o.log["n"][np.argmax(h >= 1.0)]) and n_dec > o.events["nLO"]
    assert ok and xe == 0
    assert TO.judge(o.log, o.events, 30.0, 1.0)[2] == pytest.approx(n_dec - 30.0)


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_optimize_actuation_point(backend, name):
    ac = TEMPLATES[name]()
    best, tried = TO.optimize(backend, ac, 60.0, 1.0)
    assert best.ok and best.n_dec <= 60.0
    dmax = ac.autopilot.de_max
    assert -dmax - 1e-9 <= best.de < 0                         # a maior deflexão que passa (nunca além da máx.)
    better = [r for r in tried if r.ok and r.de < best.de - 1e-9]
    assert not better                                         # nenhuma deflexão maior passou


def test_platform_landing(backend):
    ac = TEMPLATES["conventional"]()
    ac.airfield.landing_on = "plataforma"
    with Runner(backend, ac, None, dict(tmax=300)) as r:
        r.start_ground()
        o = r.run(Stop(), live=False, log=False)
    assert o.status.name == "COMPLETED" and o.events["hgnd_td"] == pytest.approx(ac.airfield.platform_height)


def test_mission_optimized_takeoff_then_stages(manager):
    ac = TEMPLATES["conventional"]()
    legs = ac.mission.names()
    r = manager.run("mission", ac, {"until": f"fim: {legs[2]}"})
    assert r.status == "STOPPED" and np.isfinite(r.summary["acionamento_profundor_m"])
    assert {f"xz_{legs[0]}", f"t3_{legs[1]}", "vel_V_a"} <= set(r.series)
    assert any(k.startswith("op_★") for k in r.series)        # ponto de acionamento escolhido
    assert any(c.item.startswith("x_warning") and c.status == "ok" for c in r.checks)


def test_start_from_stage_without_checkpoint(backend, tmp_path):
    """começar do meio sem checkpoint: voa até lá, salva e continua (antes dava erro)"""
    m = SimulationManager(backend, checkpoint_dir=str(tmp_path))
    ac = TEMPLATES["conventional"]()
    legs = ac.mission.names()
    r = m.run("mission", ac, {"start": f"início: {legs[4]}"})
    assert r.status == "COMPLETED" and "observação" in r.summary
    assert m.checkpoints.has(f"missão: início de {legs[4]}")
    assert r.log["seg"][0] == 4                                # o registro começa na etapa pedida


def test_mtow_total_mass(manager):
    """MTOW pela massa total (o padrão): o que passa da montada entra como massa no CG; a Montagem decide quanto
    é lastro, LAPES e líquido"""
    from aerosim.manager.simulations.mission import mtow_rows, total_mass
    ac = TEMPLATES["conventional"]()
    rows = mtow_rows(ac)
    assert [r["item"] for r in rows] == ["Massa total (kg)", "xCG (% CMA)"]
    m0 = total_mass(ac)
    assert rows[0]["min"] == pytest.approx(m0, abs=1e-3) and rows[0]["max"] > m0
    x = rows[1]["nom"]
    rows[1].update(min=x, max=x)
    r = manager.run("mission", ac, {"mode": MODES[3], "masses": rows})
    mt = r.summary["MTOW (kg)"]
    assert np.isfinite(mt) and rows[0]["min"] - 1e-6 <= mt <= rows[0]["max"] + 1e-6
    c = r.series["mtow_casos"]
    ok, m = c["ok"] > 0, c["m"]
    assert m[ok].max() == pytest.approx(mt, rel=1e-3) and (m[~ok] > mt).all()
    assert ac.payload.mass == 2.0 and not ac.ballast.enabled          # o avião aberto não muda
    assert r.summary["MTOW: xCG (% CMA)"] == pytest.approx(x, abs=1e-6)   # a tabela é em % da CMA


def test_mtow_xcg_old_table_in_meters(manager):
    """tabela antiga com o xCG em metros continua valendo; o resumo dá os dois"""
    from aerosim.manager.simulations.mission import ROWS, mtow_rows, xcg_pct
    from aerosim.model.universal import build_model
    ac = TEMPLATES["conventional"]()
    model = build_model(ac)
    p = mtow_rows(ac)[1]["nom"]
    x = model.x_at_mac(p / 100.0)
    assert xcg_pct(model, x) == pytest.approx(p) and xcg_pct(model, model.x_at_mac(0.25)) == pytest.approx(25.0)
    m0 = mtow_rows(ac)[0]["min"]
    rows = [dict(item=ROWS["tot"], min=m0, nom=m0, max=m0 + 3.0), dict(item="xCG (m)", min=x, nom=x, max=x)]
    r = manager.run("mission", ac, {"mode": MODES[3], "masses": rows})
    assert r.summary["MTOW: xCG (m)"] == pytest.approx(x) and r.summary["MTOW: xCG (% CMA)"] == pytest.approx(p)


def test_mtow_bisection(manager):
    """tabela antiga (mínimo, nominal, máximo): lastro, LAPES e líquido juntos; xCG nos três valores"""
    from aerosim.manager.simulations.mission import ROWS, mtow_rows
    ac = TEMPLATES["conventional"]()
    ac.ballast.enabled, ac.ballast.mass, ac.ballast.x = True, 0.3, 0.3
    x = mtow_rows(ac)[-1]["nom"]
    rows = [dict(item=ROWS["bal"], min=0.3, nom=0.3, max=0.3), dict(item=ROWS["pay"], min=2.0, nom=2.0, max=4.0),
            dict(item=ROWS["liq"], min=1.0, nom=1.0, max=2.0),   # LAPES de 2 a 4 kg, líquido de 1 a 2 L
            dict(item=ROWS["xcg"], min=x, nom=x, max=x)]           # xCG fixo (% CMA)
    r = manager.run("mission", ac, {"mode": MODES[3], "masses": rows})
    mt = r.summary["MTOW (kg)"]
    pay, liq = r.summary["MTOW: LAPES (kg)"], r.summary["MTOW: Líquido (L)"]
    assert np.isfinite(mt) and 2.0 <= pay <= 4.0 and 1.0 <= liq <= 2.0
    assert (pay - 2.0) / 2.0 == pytest.approx(liq - 1.0, abs=1e-9)     # vão juntos
    assert r.summary["MTOW: Lastro (kg)"] == pytest.approx(0.3)
    assert r.summary["MTOW: xCG (% CMA)"] == pytest.approx(x)
    c = r.series["mtow_casos"]
    ok, m = c["ok"] > 0, c["m"]
    assert m[ok].max() == pytest.approx(mt) and (m[~ok] > mt).all()


def test_simple_performance_matches_formulas(backend):
    W, S, CD0, K, CLmax = 7.32 * 9.81, 0.44, 0.0254, 0.318, 2.22
    rows, sm = backend.simple_performance(dict(W=W, S=S, CD0=CD0, K=K, CLmax=CLmax, h=900, T0=308.15,
                                               thr_V=[0, 40], thr_T=[50.1, 50.1], bank=[math.radians(30)], V_lo=5,
                                               V_hi=25, dV=0.5))
    assert sm["rho"] == pytest.approx(1.12900, abs=1e-4)                 # planilha
    i = int(np.argmin(abs(rows["V"] - 12.0)))
    CL = 2 * W / (sm["rho"] * S * 12.0 ** 2)
    assert rows["CL"][i] == pytest.approx(CL) and rows["Tr"][i] == pytest.approx(W * (CD0 + K * CL ** 2) / CL)
    assert rows["R_bank_0"][i] == pytest.approx(144 / (9.80665 * math.tan(math.radians(30))))


def test_performance_tab_is_fast_and_shaded(manager):
    import time
    t = time.time()
    r = manager.run("performance", TEMPLATES["conventional"](), {"h_list": "0, 1000"})
    assert time.time() - t < 5.0                               # só contas, sem piloto
    assert {"env_área segura", "env_V_min", "env_V_max", "scur_área segura", "spot_sobra (0 m)"} <= set(r.series)
    # curvas inteiras, também fora do envelope (como na planilha)
    assert np.isfinite(r.series["spot_P_r (0 m)"]["y"]).sum() > 0.9 * len(r.series["spot_P_r (0 m)"]["y"])


def test_example_aircraft_folder_lists_everything():
    import os
    from aerosim.data.projects import list_folder, load_file
    root = os.path.join(os.path.dirname(__file__), "..", "..", "data", "aircraft")
    items = list_folder(root)
    assert len(items) >= 7
    for it in items:
        assert load_file(it.path).surfaces


def test_mission_battery_glyphs_and_editable_trajectory(manager):
    ac = TEMPLATES["conventional"]()
    sim = manager.get("mission")
    rows = sim.parameters_for(ac, {})[1].default                     # tabela da trajetória
    rows[2]["length"] = 150.0                                         # encurta o cruzeiro 1
    assert sim.commit(ac, {"legs": rows}) and ac.mission.legs[2].length == 150.0
    r = manager.run("mission", ac, {"until": f"fim: {ac.mission.names()[3]}"})
    assert any(k.startswith("t3_✈") for k in r.series)               # avião desenhado na trajetória
    c = r.series["consumo_por_etapa"]
    assert c["etapa"][-1] == "total" and c["consumo_mAh"][-1] > 0
    soc = r.series["batp_SOC Peukert"]["y"]                           # SOC: começa em 100 % e cai
    assert soc[0] == pytest.approx(100.0, abs=0.5) and soc[-1] < soc[0] and c["soc_fim_pct"][-1] < 100
    assert any(k.startswith("dt_θ + i_w") for k in r.series)    # θ e θ + incidência na decolagem
    assert ac.mission.segments()[-1]["e0"] == pytest.approx(20.0)     # pouso 20 m a leste da decolagem


def test_ballast_changes_mass_cg_and_inertia(backend):
    """lastro: massa pontual — muda massa, CG e inércias (Steiner), e o núcleo vê isso"""
    from aerosim.model.universal import build_model
    ac = TEMPLATES["conventional"]()
    a = build_model(ac).mass
    ac.ballast.enabled, ac.ballast.mass, ac.ballast.x = True, 0.5, 0.6
    b = build_model(ac).mass
    assert b["m"] == pytest.approx(a["m"] + 0.5)
    assert b["cg"][0] == pytest.approx((a["m"] * a["cg"][0] + 0.5 * 0.6) / (a["m"] + 0.5))
    assert b["I"][1, 1] > a["I"][1, 1]
    with backend.session_for(build_model(ac)) as s:
        assert s.mass_props()["cg"][0] > 0.0 and s.mass_props()["m"] > a["m"]


def test_mission_table_turn_angle_and_auto_radius(manager):
    """tabela simples: 'virar (°)' com sinal (− esquerda) e raio vazio = automático (procura o menor que passa)"""
    from aerosim.manager.simulations.mission import legs_to_rows, rows_to_legs
    ac = TEMPLATES["conventional"]()
    rows = legs_to_rows(ac.mission.legs)
    assert rows[0]["kind"] == "decolagem" and rows[-1]["kind"] == "pouso" and rows[1]["kind"] == "curva"
    rows[1]["turn"], rows[1]["radius"] = -90.0, None
    legs = rows_to_legs(rows, ac.mission.legs)
    assert legs[1].side == -1 and legs[1].angle == 90.0 and legs[1].radius == 0.0
    assert legs[0].takeoff and legs[-1].landing
    ac.mission.legs = legs
    assert ac.mission.segments()[1]["R"] > 3.0                        # raio provisório para desenhar
    r = manager.run("mission", ac, {"until": f"fim: {ac.mission.names()[1]}"})
    R = r.summary[f"raio automático — {ac.mission.names()[1]}"]
    assert 3.0 < R < 80.0
    assert any(c.item.startswith("raio automático") for c in r.checks)


def test_turns_show_load_factor(manager):
    """curvas: raio mínimo — o fator de carga em regime de cada raio e no raio mínimo, com o n de projeto"""
    ac = TEMPLATES["conventional"]()
    r = manager.run("mission", ac, {"mode": MODES[2], "V_list": "15"})
    assert any(k.startswith("cn_V = 15") for k in r.series) and any(k.startswith("cn_n de projeto") for k in r.series)
    n = r.summary["n no R_min @ 15 m/s"]
    assert np.isfinite(n) and n > 1.0
    assert any(c.item == "fator de carga no raio mínimo a 15 m/s" for c in r.checks)
