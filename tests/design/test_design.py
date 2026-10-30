"""Etapas da sprint (aerosim/design): perfil → asa → empenagem → motores → avião inteiro."""
import math

import numpy as np
import pytest

from aerosim.design import airfoils as afm
from aerosim.design import power as pw
from aerosim.design import tail as tl
from aerosim.design import wing as wg
from aerosim.design.project import DesignProject, next_name
from aerosim.design.spec import Requirements
from aerosim.model.airfoil import helmbold


def _wing(**kw):
    p = wg.WingParams(**kw)
    return wg.WingCandidate(p, afm.AirfoilEntry(afm.from_naca("NACA 2412")))


def test_wing_geometry_matches_params():
    for rf, lam in ((0.0, 0.5), (0.4, 0.6), (1.0, 1.0)):
        p = wg.WingParams(span=2.2, area=0.8, rect_frac=rf, taper=lam)
        w = wg.build_wing(p, afm.from_naca("NACA 2412"))
        assert w.area == pytest.approx(0.8) and w.span == pytest.approx(2.2)


def test_lifting_line_rectangular_vs_helmbold_and_stall_at_root():
    r = wg.analyze(_wing(span=2.4, area=0.72, rect_frac=1.0, twist=0.0), Requirements())
    a1 = r["airfoil"].cl_alpha
    assert r["CLa"] == pytest.approx(helmbold(a1, 8.0), rel=0.03)
    assert r["eta_stall"] < 0.1                     # retangular estola na raiz
    assert 0.9 < r["e"] <= 1.0


def test_taper_moves_stall_out_and_washout_brings_it_back():
    base = dict(span=2.4, area=0.72, rect_frac=0.0, taper=0.35)
    out = wg.analyze(_wing(twist=0.0, **base), Requirements())["eta_stall"]
    back = wg.analyze(_wing(twist=-4.0, **base), Requirements())["eta_stall"]
    assert out > 0.5 and back < out


def test_near_elliptic_planform_has_e_close_to_one():
    r = wg.analyze(_wing(span=2.4, area=0.72, rect_frac=0.0, taper=0.4, twist=0.0), Requirements())
    assert r["e"] > 0.97


def test_incidence_puts_fuselage_at_cruise_angle():
    req = Requirements()
    r = wg.analyze(_wing(area=1.0, alpha_cruise=2.0), req)
    assert r["incidence"] == pytest.approx(r["alpha_cruise_w"] - 2.0)
    assert r["CL_cruise"] == pytest.approx(req.weight / (req.q() * r["S"]))


def test_tail_sizing_by_volume_and_cg_range():
    req = Requirements()
    sc = tl.SetCandidate(tl.TailParams(VH=0.5, VV=0.04, arm=1.0), _wing(area=1.0))
    r = tl.analyze(sc, req)
    i = r["info"]
    assert i["Sh"] == pytest.approx(0.5 * i["S"] * i["c"] / 1.0)
    assert i["Sv"] == pytest.approx(0.04 * i["S"] * i["b"] / 1.0)
    assert r["h_n"] > r["h_ac"]                                  # a cauda leva o ponto neutro para trás
    assert r["h_fwd"] < r["h_cg"] < r["h_aft"] < r["h_n"]
    assert r["h_n"] - r["h_cg"] == pytest.approx(0.12)
    assert abs(r["de_cruise"]) < 1e-6                            # incidência da EH equilibra o cruzeiro
    assert r["de_CLmax"] < 0                                     # cabrar para o C_L,max
    ac = r["set"]                                                # a cauda na ponta do tubo
    eh = ac.surfaces[1]
    assert eh.x - eh.sections[0].chord == pytest.approx(ac.boom.x_end)


def test_v_tail_keeps_total_area_and_flying_wing_has_no_tail():
    req = Requirements()
    v = tl.analyze(tl.SetCandidate(tl.TailParams(layout="em V"), _wing(area=1.0)), req)
    assert v["set"].surfaces[1].area == pytest.approx(v["info"]["Sh"] + v["info"]["Sv"])
    assert v["set"].surfaces[1].controls[0].kind == "ruddervator"
    f = tl.analyze(tl.SetCandidate(tl.TailParams(layout="sem cauda"), _wing(area=1.0)), req)
    assert len(f["set"].surfaces) == 1 and f["set"].surfaces[0].controls[0].kind == "elevon"


def test_assembly_puts_cg_on_target_and_flies_in_the_core(manager, tmp_path):
    from aerosim.data import load_aircraft, save_aircraft
    from aerosim.model.massprops import dry_mass
    req = Requirements(mass=8.0)                       # massa de projeto (a CP estimada é o que passa do PV)
    cand = pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    ac, asm = pw.assemble(cand, req)
    dm = dry_mass(ac)
    assert asm["battery_fits"] and dm["cg"][0] == pytest.approx(asm["x_cg_target"], abs=1e-6)
    pp = cand.params
    # a sprint só diz se tem LAPES e líquido: o avião sai com eles no CG e sem kg (a Montagem decide); as contas
    # usam a massa de projeto (massa estimada) e a CP estimada é o que passa do PV
    assert dm["m"] == pytest.approx(asm["empty"]) and asm["mass"] == pytest.approx(req.mass)
    assert asm["payload"] == pytest.approx(req.mass - asm["empty"]) and asm["sm"] == pytest.approx(12.0)
    assert asm["empty"] + asm["payload"] == pytest.approx(sum(r[2] for r in asm["mass_table"]))
    assert pp.lapes and pp.liquid and ac.payload.enabled and ac.payload.mass == 0.0 and ac.payload.count == pp.n_lapes
    assert len(ac.tanks) == pp.n_tanks and all(t.volume == 0.0 for t in ac.tanks) and not ac.ballast.enabled
    assert all(t.x == pytest.approx(asm["x_cg_target"]) for t in ac.tanks) and ac.payload.x == pytest.approx(asm["x_cg_target"])
    assert ac.gear.main_x < asm["x_cg_target"] < ac.gear.steer_x       # triciclo: principal atrás do CG
    f = str(tmp_path / "a.json")
    save_aircraft(ac, f)
    ac2 = load_aircraft(f)
    pf = pw.performance(ac2, asm, req, manager.backend)
    assert pf["T0"] > 0 and pf["s_to"] < req.takeoff_run and math.isfinite(pf["mtow_runway"])
    assert pf["mtow_runway"] > asm["mass"]
    assert manager.run("performance", ac2, {}).status in ("ok", "COMPLETED")


def test_payload_options_count_and_old_files():
    """tem LAPES / líquido e quantos; sem nenhum, nada de carga no avião; projeto antigo (kg) vira opção"""
    from aerosim.model.serialize import from_dict
    set_ = tl.SetCandidate(tl.TailParams(), _wing(area=1.0))
    ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(lapes=True, n_lapes=3, liquid=True, n_tanks=2), set_),
                          Requirements())
    assert ac.payload.count == 3 and [t.name for t in ac.tanks] == ["tanque 1", "tanque 2"]
    assert ac.tanks[0].y == pytest.approx(-ac.tanks[1].y) and ac.tanks[0].y != 0
    ac, _ = pw.assemble(pw.AircraftCandidate(pw.PowerParams(lapes=False, liquid=False), set_), Requirements())
    assert not ac.payload.enabled and not ac.tanks
    assert not any(e.kind == "drop" for e in ac.mission.events)            # sem LAPES, sem soltura
    old = from_dict(pw.PowerParams, dict(ballast=2.0, liquid=1.0, lapes=0.0))
    assert old.liquid is True and old.lapes is False and not hasattr(old, "ballast")


def test_tandem_neutral_point_uses_both_wings_and_the_rear_wing_pitches(manager):
    """tandem: a asa de trás é a cauda. O ponto neutro fica entre os dois CA (antes era o da asa da frente sozinha),
    o profundor fica na de trás e ela sente o downwash da da frente; o tubo que liga as duas é da Montagem, não da
    etapa; o ponto neutro do núcleo fica
    perto do da sprint (a menos de 15 % da CMA) e o profundor de trás para cima cabra"""
    import copy
    from aerosim.model.universal import build_model
    w = _wing(span=2.4, area=0.8)
    tp = tl.TailParams(layout="sem cauda", wing2=tl.SAME_WING, wing2_dx=1.0, wing2_dz=0.1, wing2_di=-6.0,
                       sm_target=8.0)
    cand = pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(tp, w, wing2=copy.deepcopy(w)))
    st = tl.analyze(cand.set, Requirements())
    x1, x2 = st["info"]["x_ac_w"], st["x_ac_2"]
    assert x2 < st["x_np"] < x1 and st["x_np"] < x1 - 0.2 * (x1 - x2)
    ac, asm = pw.assemble(cand, Requirements())
    front, rear = ac.surfaces[0], ac.surfaces[-1]
    assert [c.kind for c in front.controls] == ["aileron"] and [c.kind for c in rear.controls] == ["elevator"]
    assert rear.downwash and rear.mount == "" and not ac.boom.enabled
    m = build_model(ac)
    with manager.backend.session_for(m) as s:
        k1, k2 = s.aero_coeffs(10.0, math.radians(2)), s.aero_coeffs(10.0, math.radians(4))
        up = s.aero_coeffs(10.0, math.radians(2), de=-math.radians(15))
    x_np_core = m.mass["cg"][0] + (k2["Cm"] - k1["Cm"]) / (k2["CL"] - k1["CL"]) * m.c
    assert abs(x_np_core - st["x_np"]) < 0.15 * st["info"]["c"]       # o resto da diferença: O21 no tracking
    assert up["Cm"] > k1["Cm"]


def test_tip_fins_give_the_tailless_aircraft_directional_stability():
    """a deriva na ponta (que também é winglet) é a única coisa que aponta o nariz no vento num avião sem cauda: sem
    ela o C_nβ não existe, com ela cresce com a altura, e no tandem o lugar com braço é a asa de trás"""
    import copy
    w = _wing(span=2.4, area=0.8)
    def cnb(fin, **kw):
        tp = tl.TailParams(layout="sem cauda", tip_fin=fin, **kw)
        wing2 = copy.deepcopy(w) if kw.get("wing2") else None
        return tl.analyze(tl.SetCandidate(tp, w, wing2=wing2), Requirements())
    assert math.isnan(cnb(0.0)["Cnb"])
    small, big = cnb(0.12)["Cnb"], cnb(0.24)["Cnb"]
    assert 0 < small < big
    ac, _ = pw.assemble(pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(
        tl.TailParams(layout="sem cauda", tip_fin=0.2), w)), Requirements())
    fins = [s for s in ac.surfaces if s.role == "vtail"]
    assert len(fins) == 2 and all(s.vertical and s.mount.startswith("ponta_") for s in fins)
    assert [c.kind for s in fins for c in s.controls] == ["rudder", "rudder"]
    base = dict(wing2=tl.SAME_WING, wing2_dx=1.0)
    rear = cnb(0.2, **base, tip_fin_where=tl.TIP_FIN_WHERE[0])["Cnb"]
    front = cnb(0.2, **base, tip_fin_where=tl.TIP_FIN_WHERE[1])["Cnb"]
    assert rear > 10 * front                     # a ponta da asa da frente fica quase no CG


def test_tip_fins_do_not_move_the_tandem_neutral_point():
    """as derivas da ponta entram na lista depois da asa de trás; a estática do tandem tem de achar a asa de trás
    pelo papel, não pelo fim da lista. Antes ela lia a deriva como asa de trás: o ponto neutro ia para a asa da
    frente, o comando não trimava e a E&C pedia perto de 1 kg de lastro. Deriva vertical não muda o ponto neutro"""
    import copy
    w = _wing(span=2.4, area=0.8)
    def np_(fin):
        tp = tl.TailParams(layout="sem cauda", wing2=tl.SAME_WING, wing2_dx=1.0, wing2_dz=0.1, wing2_di=-6.0,
                           sm_target=8.0, tip_fin=fin)
        st = tl.analyze(tl.SetCandidate(tp, w, wing2=copy.deepcopy(w)), Requirements())
        return st, tl.second_wing(st["set"])
    (st0, w0), (st1, w1) = np_(0.0), np_(0.2)
    assert w1.role == "wing" and not w1.vertical and w1.name == w0.name
    assert st1["x_np"] == pytest.approx(st0["x_np"], abs=1e-9)
    assert st1["Cmde"] == pytest.approx(st0["Cmde"], rel=1e-9)
    assert [c.kind for c in w1.controls] == ["elevator"]


def test_tandem_rear_wing_area_ratio_and_airfoil():
    """a razão de áreas (`wing2_area`) multiplica as cordas da asa de trás com a mesma envergadura, e o ponto neutro
    anda para trás com ela (a de trás pesa mais na média dos CA). Com 1 e sem perfil, a asa de trás é a cópia de
    sempre; com `wing2_airfoil` ela leva esse perfil em toda a envergadura e a da frente fica com o dela"""
    import copy
    w = _wing(span=2.4, area=0.8)
    def st(**kw):
        tp = tl.TailParams(layout="sem cauda", wing2=tl.SAME_WING, wing2_dx=1.0, wing2_dz=0.1, wing2_di=-2.0,
                           sm_target=8.0, **kw)
        w2 = tl.wing2_candidate(w, tp, {"NACA 0012": afm.entry(afm.from_naca("0012"))}.get)
        out = tl.analyze(tl.SetCandidate(tp, w, wing2=w2), Requirements())
        return out, out["set"].surfaces[0], tl.second_wing(out["set"])
    (s1, f1, r1), (s2, f2, r2) = st(), st(wing2_area=1.5)
    assert r1.area == pytest.approx(f1.area) and r2.area == pytest.approx(1.5 * f2.area)
    assert r2.span == pytest.approx(f2.span)
    assert s2["x_np"] < s1["x_np"]                             # x + para a frente: o ponto neutro foi para trás
    _, f3, r3 = st(wing2_airfoil="NACA 0012")
    assert r3.airfoil.name == "NACA 0012" and f3.airfoil.name != "NACA 0012"
    # outro perfil: a decalagem é entre as linhas de sustentação nula (com o NACA 0012 atrás, uma incidência maior)
    a0 = lambda s: -wg.lifting_line(s)["At"][0] / wg.lifting_line(s)["Aa"][0]
    assert r3.incidence == pytest.approx(f3.incidence - 2.0 + math.degrees(a0(r3) - a0(f3)))
    assert r3.incidence > f3.incidence - 2.0
    s5, f5, r5 = st(wing2_area=2.0, wing2_span=1.5)        # a de trás maior também na envergadura
    assert r5.span == pytest.approx(1.5 * f5.span) and r5.area == pytest.approx(2.0 * f5.area)
    s6, _, r6 = st(wing2_area=2.0, wing2_span=1.5, wing2_sweep=20.0)
    assert r6.sections[-1].x_offset > r5.sections[-1].x_offset and s6["x_np"] < s5["x_np"]
    _, _, r4 = st(wing2_airfoil="não existe")
    assert r4.airfoil.name == f3.airfoil.name


def test_payload_position_is_a_variable_and_zero_keeps_the_old_assembly():
    """a posição da carga paga é variável do otimizador (`power.x_payload`, do CG de projeto), não regra da sprint
    (O27). Com 0 a montagem é a de sempre; com a carga atrás do CG a bateria vai para a frente para equilibrar, a
    carga fica no x pedido e, sem ela, o CG anda para a frente (a margem sem a carga cresce)"""
    w = _wing(area=1.0)
    def asm(xp):
        return pw.assemble(pw.AircraftCandidate(pw.PowerParams(lapes=True, x_payload=xp), tl.SetCandidate(
            tl.TailParams(), w)), Requirements())
    ac0, a0 = asm(0.0)
    assert not a0["payload_moved"] and a0["x_payload"] == a0["x_cg_target"] and a0["sm_empty"] == pytest.approx(a0["sm"])
    ac, a = asm(-0.05)
    assert a["payload_moved"] and ac.payload.x == pytest.approx(a["x_cg_target"] - 0.05)
    assert a["x_bat_used"] > a0["x_bat_used"] and a["battery_fits"]
    assert a["sm_empty"] > a["sm"]


def test_obstacle_height_sets_the_6dof_takeoff_and_old_projects_keep_one_meter():
    """a altura do obstáculo (Regular 2026: 0,90 m a 55 m) vira o z_warning da decolagem 6GDL; sem ela, 1 m como antes"""
    from aerosim.model.serialize import from_dict
    set_ = tl.SetCandidate(tl.TailParams(), _wing(area=1.0))
    cand = pw.AircraftCandidate(pw.PowerParams(), set_)
    ac, _ = pw.assemble(cand, Requirements())
    assert ac.airfield.z_warning == 1.0
    req = Requirements()
    req.takeoff_run, req.obstacle_h = 55.0, 0.9
    ac, _ = pw.assemble(cand, req)
    assert (ac.airfield.x_warning, ac.airfield.z_warning) == (55.0, 0.9)
    assert from_dict(Requirements, dict(mass=12.0)).obstacle_h == 1.0


def test_python_thrust_matches_core(manager):
    cand = pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    ac, _ = pw.assemble(cand, Requirements())
    V = np.array([0.0, 8.0, 16.0])
    assert pw.thrust_of(ac, V, 1.15, None) == pytest.approx(pw.thrust_of(ac, V, 1.15, manager.backend), rel=0.03)


def test_pusher_with_boom_is_flagged():
    cand = pw.AircraftCandidate(pw.PowerParams(layout="propulsora atrás da asa"),
                                tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    _, asm = pw.assemble(cand, Requirements())
    assert asm["boom_hits_prop"]


def test_xflr5_polar_file(tmp_path):
    txt = """xflr5 v6.47

 Calculated polar for: NACA 2412

 1 1 Reynolds number fixed          Mach number fixed

 xtrf =   1.000 (top)        1.000 (bottom)
 Mach =   0.000     Re =     0.300 e 6     Ncrit =   9.000

  alpha      CL        CD       CDp       Cm    Top Xtr  Bot Xtr   Cpmin    Chinge    XCp
 -------- -------- --------- --------- -------- ------- ------- -------- --------- ---------
  -4.000  -0.2100   0.01000   0.00400  -0.0500  0.9000  0.1000  -1.0000   0.0000   0.2000
   0.000   0.2300   0.00800   0.00300  -0.0520  0.7000  0.9000  -1.0000   0.0000   0.2000
   4.000   0.6700   0.00900   0.00400  -0.0540  0.5000  1.0000  -1.0000   0.0000   0.2000
   8.000   1.0500   0.01300   0.00700  -0.0500  0.2000  1.0000  -1.0000   0.0000   0.2000
  12.000   1.3000   0.02200   0.01500  -0.0400  0.1000  1.0000  -1.0000   0.0000   0.2000
  14.000   1.2500   0.04000   0.03000  -0.0400  0.1000  1.0000  -1.0000   0.0000   0.2000
"""
    f = tmp_path / "naca2412_T1_Re0.300.txt"
    f.write_text(txt)
    p = afm.read_polar_file(str(f))
    assert p["Re"] == pytest.approx(3e5) and list(p["alpha"]) == [-4, 0, 4, 8, 12, 14]
    e = afm.AirfoilEntry(afm.Airfoil(name="só parâmetros"), source="arquivo", polar_file=str(f))
    assert afm.kind(e.airfoil) == "parâmetros" and "arquivo" in afm.sources(e) and "neuralfoil" not in afm.sources(e)
    m = afm.metrics(afm.polar(e, 3e5, np.arange(-4, 14.01, 0.5)))
    assert m["cl_max"] == pytest.approx(1.3) and m["alpha0"] == pytest.approx(-2.1, abs=0.2)
    assert not m["cd_const"] and m["cd_min"] == pytest.approx(0.008, abs=1e-3)


def test_project_roundtrip_and_names(tmp_path):
    p = DesignProject()
    p.wing_draft.area = 1.0
    w = p.keep_wing()
    assert w.name == "asa 1" and p.wing_draft.name == "asa 2"
    p.tail_draft.wing = w.name
    s = p.keep_set()
    p.power_draft.set = s.name
    p.keep_aircraft()
    f = str(tmp_path / "sprint.json")
    p.save(f)
    q = DesignProject.load(f)
    assert [x.name for x in q.wings] == ["asa 1"] and q.aircraft[0].set.wing.params.area == 1.0
    assert next_name("conjunto 1", ["conjunto 1", "conjunto 2"]) == "conjunto 3"


def test_tilted_motor_shortens_the_run():
    req = Requirements()
    st = tl.SetCandidate(tl.TailParams(), _wing(area=1.0))
    out = []
    for tilt in (0.0, 8.0):
        ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(tilt=tilt), st), req)
        out.append(pw.performance(ac, asm, req, None)["s_to"])
    assert out[1] < out[0]


def test_cambered_inverted_tail_needs_other_incidence():
    req = Requirements()
    r0 = tl.analyze(tl.SetCandidate(tl.TailParams(), _wing(area=1.0)), req)
    r1 = tl.analyze(tl.SetCandidate(tl.TailParams(tail_airfoil="NACA 4412", tail_inverted=True), _wing(area=1.0)), req)
    assert r1["set"].surfaces[1].airfoil.zero_lift_angle() > 2          # invertido: α_L0 positivo
    assert r1["i_h"] > r0["i_h"] + 2 and abs(r1["de_cruise"]) < 1e-6


def test_inverted_tail_rotates_earlier():
    """EH com perfil arqueado invertido: c_l negativo maior → roda o avião mais cedo na corrida"""
    req = Requirements()
    w = _wing(area=1.0, alpha_cruise=3.0)
    sym = tl.analyze(tl.SetCandidate(tl.TailParams(), w), req)
    up = tl.analyze(tl.SetCandidate(tl.TailParams(tail_airfoil="NACA 6412", tail_inverted=True), w), req)
    assert up["CLh_lim"][0] < sym["CLh_lim"][0]            # mais c_l para baixo
    assert up["V_rot"] < sym["V_rot"]


def test_tilted_motor_retrims_tail_and_differential_aileron():
    req = Requirements()
    st = tl.SetCandidate(tl.TailParams(), _wing(area=1.0, alpha_cruise=3.0))
    ih = []
    for tilt in (0.0, 8.0):
        ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(tilt=tilt), st), req)
        ih.append(ac.surfaces[1].incidence)
        assert set(asm["trim"]) >= {"Cm_T", "dih", "hold", "V_rot", "V_lof"}
    assert ih[1] > ih[0]                       # inclinado para cima cabra no cruzeiro: a EH compensa
    from aerosim.design.spec import DesignRules
    sym = tl.analyze(st, req, DesignRules(da_max=20, da_down=20))["pb2V"]
    dif = tl.analyze(st, req, DesignRules(da_max=20, da_down=10))["pb2V"]
    assert dif == pytest.approx(0.75 * sym)


def test_design_point_converges_and_study_marks_best():
    """ponto de projeto acoplado: a massa de projeto converge no MTOW; o estudo marca o maior MTOW viável"""
    from aerosim.design import study as sd
    p = DesignProject()
    p.wing_draft.area, p.wing_draft.alpha_cruise = 1.0, 3.0
    p.requirements.V_stall_max = 13.0                      # restrição de estol no MTOW que este avião cumpre
    p.requirements.takeoff_run = 50.0                      # cenário com pista longa (o padrão SAE é 6 m)
    w = p.keep_wing()
    p.tail_draft.wing = w.name
    p.power_draft.set = p.keep_set().name
    d = pw.design_point(p.draft_aircraft(), p.requirements, p.rules, None, p.airfoil_map())
    assert d["converged"] and d["asm"]["mass"] == pytest.approx(d["mtow"], abs=0.05)
    # com poucas voltas a média não chega; a secante termina e cai no mesmo MTOW
    few = pw.design_point(p.draft_aircraft(), p.requirements, p.rules, None, p.airfoil_map(), iters=2)
    assert few["converged"] and few["mtow"] == pytest.approx(d["mtow"], abs=0.05)
    sp = sd.StudyParams(start=0.0, stop=8.0, n=2, places="A=0, B=1500")
    rows = sd.run(p, sp)
    assert len(rows) == 4 and {r["place"] for r in rows} == {"A", "B"}
    best = sd.best_rows(rows)
    assert best["A"]["mtow"] > best["B"]["mtow"]           # ar mais rarefeito leva menos
    plots, res = sd.result(rows, sp)
    assert any(c.item.startswith("A: maior MTOW") for c in res.checks)
    assert sd.parse_places("", 600.0) == [("AD 600 m", 600.0)]


def test_constraints_registry_and_old_requirements():
    """restrições ligáveis com operador; os limites antigos viram restrições; PV/MTOW são saídas"""
    from aerosim.design import registry as rg
    from aerosim.design.spec import Requirements
    from aerosim.model.serialize import from_dict, to_dict
    old = from_dict(Requirements, {"mass": 8, "span_max": 0, "takeoff_run": 3, "V_stall_max": 9})
    assert old.takeoff_run == 3 and old.V_stall_max == 9 and old.span_max == 0      # b ≤ 0 desligada
    assert from_dict(Requirements, to_dict(old)).takeoff_run == 3
    c = rg.Constraint("ee", "≥", 1.0)
    assert c.holds(1.2) and not c.holds(0.8)
    off = rg.Constraint("b", "≤", 2.0, active=False)
    assert [(x[0], x[1]) for x in rg.checks([c, off], {"ee": 0.5, "b": 3.0})] == [(c, False)]   # a desligada não conta
    req = Requirements()
    req.constraints = [rg.Constraint("s_to", "≤", 3.0)]
    assert req.takeoff_run == 3.0 and req.span_max == 0.0
    req.constraints[0].active = False
    assert req.takeoff_run > 100                                                    # desligada: sem limite
    p = DesignProject()
    rg.set_input(p, "wing.span", 2.0)
    assert rg.get_input(p, "wing.span") == 2.0 and p.wing_draft.span == 2.0
    assert {v.key: v.mode for v in p.variables}["req.mass"] == "calculado"
    assert all(rg.QUANTITIES[k].label for k in ("mtow", "pv", "ee"))


def test_wing_with_root_and_tip_airfoils():
    """a mesma asa com dois perfis: a1, α_L0 e c_l,max locais interpolados; o mesmo perfil na ponta não muda nada"""
    p = DesignProject()
    p.airfoils.append(afm.entry(afm.from_naca("NACA 0012")))
    p.wing_draft.rect_frac, p.wing_draft.airfoil = 0.4, "NACA 4412"
    one = wg.analyze(p.draft_wing(), p.requirements)
    p.wing_draft.airfoil_tip = "NACA 4412"
    assert p.draft_wing().airfoil_tip is None                 # igual à raiz: um perfil só
    p.wing_draft.airfoil_tip = "NACA 0012"
    two = wg.analyze(p.draft_wing(), p.requirements)
    assert two["airfoil_tip"] is not None and two["CL0"] < one["CL0"]       # ponta simétrica: menos C_L0
    clm, eta = two["cl_max_local"], two["span_eta"]
    rect = clm[eta < 0.39]                                    # trecho retangular: só o perfil da raiz
    assert np.ptp(rect) < 1e-12 and clm[-1] < rect[0]
    s = two["surface"]
    assert max(s.sections, key=lambda q: q.y).airfoil.name == "NACA 0012" and s.mixed_airfoils


def _var(p, key, mode, lo=None, hi=None):
    v = next(v for v in p.variables if v.key == key)
    v.mode = mode
    if lo is not None:
        v.lo, v.hi = lo, hi
    return v


def test_mdo_core_chain_kinds_and_3m_runway():
    """mini-MDO no núcleo: corrida ≤ 3 m — o monoplano não cumpre, o VTOL paira; o melhor respeita as restrições"""
    from aerosim.design import mdo, registry as rg
    p = DesignProject()
    p.requirements.constraints = [rg.Constraint("s_to", "≤", 3.0)]
    p.mdo.particles, p.mdo.iterations = 6, 3
    _var(p, "power.motors", "fixo")
    p.power_draft.wing_motors = 8                           # ~26 N por conjunto de 1,25 kg: 8 pairam com margem 1,3
    p.power_draft.layout = "dois motores na asa"            # o nariz só aceita 1 motor; na asa, aos pares
    p.power_draft.layout = "dois motores na asa"            # o nariz só aceita 1 motor; na asa, aos pares
    row = mdo.run(p)[0][0]
    p.mdo.kind = "monoplano"
    mono = mdo.evaluate(p, row)
    p.mdo.kind = "VTOL"
    vtol = mdo.evaluate(p, row)
    assert not mono["feasible"] and vtol["hover"] and vtol["q"]["s_to"] == 0.0
    p.requirements.constraints = [rg.Constraint("b", "≤", 2.0), rg.Constraint("s_to", "≤", 60.0)]
    for v in p.variables:
        if v.key in ("wing.span", "wing.area"):
            v.mode = "variável"
    p.mdo.kind = "biplano"
    p.power_draft.layout = "tratora no nariz"
    rows, best, names = mdo.run(p)
    q = dict(zip(names["quantities"], best["q"]))
    assert best["feasible"] and q["b"] <= 2.0 + 1e-9 and q["s_to"] <= 60.0 + 1e-6
    assert q["mtow"] == pytest.approx(max(r["mtow"] for r in rows if r["feasible"]), rel=1e-9)


def test_mdo_layout_and_lists_default_to_all():
    """arranjo é variável: na asa os motores vão aos pares; listas variáveis sem escolha = tudo (pasta de perfis)"""
    from aerosim.design import mdo
    from aerosim.design.power import LAYOUTS
    p = DesignProject()
    for v in p.variables:
        if v.key in ("power.layout", "wing.airfoil"):
            v.mode = "variável"
    _var(p, "power.motors", "variável", 1, 4)
    p.mdo.particles, p.mdo.iterations = 12, 4
    rows, best, names = mdo.run(p)
    # o arranjo livre (nariz + asa + atrás) não tem modelo no dimensionamento do núcleo: fica de fora da lista
    assert names["layouts"] == [l for l in LAYOUTS if l in mdo.LAYOUT_DATA] and len(names["airfoils"]) >= 9
    for r in rows:
        if r["layout"] == LAYOUTS[1]:
            assert r["motors"] % 2 == 0
        else:
            assert r["motors"] == 1
    wing = next(r for r in rows if r["layout"] == LAYOUTS[1])
    mdo.apply(p, wing)
    assert p.power_draft.layout == LAYOUTS[1] and p.power_draft.wing_motors == wing["motors"]
    assert p.airfoil(wing["airfoil"]) is not None              # perfil da pasta entrou no projeto


def test_mdo_full_envelope_and_constraint_diagram():
    """o indivíduo por inteiro: todas as velocidades do desempenho do núcleo e o diagrama com as curvas escolhidas"""
    from aerosim.design import mdo
    p = DesignProject()
    p.mdo.particles, p.mdo.iterations = 6, 2
    rows, best, names = mdo.run(p)
    h = mdo.history(rows)[-1]
    ev = mdo.evaluate(p, h)
    env = mdo.full_envelope(p, h, ev)
    s = env["summary"]
    assert s["Vs"] == pytest.approx(ev["q"]["V_S"], rel=0.02) and s["Vmax"] > s["V_LDmax"] > s["Vs"]
    assert len(env["rows"]["V"]) > 40 and np.all(np.isfinite(env["rows"]["Tr"]))      # a curva inteira
    d = mdo.constraint_diagram(p, h, ev, env, ("estol", "decolagem", "curva"))
    assert set(d["curves"]) == {"ws", "decolagem", "curva"} and "estol" in d["limits"]
    assert d["point"][0] == pytest.approx(h["mtow"] * 9.80665 / h["area"], rel=1e-6)
