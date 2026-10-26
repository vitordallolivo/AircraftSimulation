"""aeroopt em etapas: a barreira entre etapas, as configurações, o dimensionamento das superfícies pela decolagem,
o 6GDL e a nota no núcleo."""
import copy
import math

import pytest

import aeroopt
from aeroopt import stages as sg
from aeroopt.pipeline import Pipeline
from aerosim.design.project import DesignProject
from aerosim.interfaces.optim import IStage, StageItem


class Square(IStage):
    name = "quadrado"

    def __init__(self, parallel):
        self.parallel = parallel

    def one(self, it):
        if it.values["x"] == 3:
            raise ValueError("três não")
        it.data["y"] = it.values["x"] ** 2
        return it


class Rank(IStage):
    """lote: precisa de todos prontos (a barreira) para saber a posição de cada um"""
    name = "posição"
    batch = True

    def run(self, items):
        ys = sorted(i.data["y"] for i in items)
        for i in items:
            i.data["pos"] = ys.index(i.data["y"])
        return items

    def select(self, items):
        return [i for i in items if i.data["pos"] < 3]


@pytest.mark.parametrize("parallel", ["não", "threads", "processos"])
def test_pipeline_barrier_select_and_failures(parallel):
    items = [StageItem(f"c{x}", {"x": x}) for x in range(6)]
    p = Pipeline([Square(parallel), Rank()])
    out = p.run(items, workers=3)
    assert [i.name for i in out] == [f"c{x}" for x in range(6)]          # a ordem não depende do paralelismo
    assert [i.data.get("y") for i in out] == [0, 1, 4, None, 16, 25]
    assert not out[3].alive and "três não" in out[3].why                 # quem quebra para ali; os outros seguem
    assert [i.name for i in out if i.alive] == ["c0", "c1", "c2"]
    assert out[5].why == "posição: não foi escolhido"
    assert p.log == [("quadrado", 6, 5), ("posição", 5, 3)]


class Slow(IStage):
    name = "devagar"
    parallel = "processos"

    def one(self, it):
        import time
        time.sleep(30)
        return it


def test_stop_does_not_wait_for_running_work():
    """o Parar não espera a conta que está rodando num processo terminar: o processo é encerrado"""
    import time
    t0 = time.time()
    out = Pipeline([Slow()]).run([StageItem(f"c{x}") for x in range(4)], workers=2,
                                 cancel=lambda: time.time() - t0 > 1.0)
    assert time.time() - t0 < 8 and all(not i.alive and "cancelado" in i.why for i in out)


def _project():
    p = DesignProject()
    p.wing_draft.area, p.wing_draft.alpha_cruise = 1.0, 3.0
    p.requirements.V_stall_max = 13.0
    p.requirements.takeoff_run = 50.0                      # pista longa: este avião decola nela
    w = p.keep_wing()
    p.tail_draft.wing = w.name
    p.power_draft.set = p.keep_set().name
    return p


def test_configurations_are_the_discrete_combinations():
    p = _project()
    for v in p.variables:
        if v.key in ("power.propeller", "power.motors", "wing.span"):
            v.mode = "variável"
            v.options = ["APC 15x8E", "Genérica 11x7"] if v.key == "power.propeller" else []
            v.lo, v.hi = (2, 4) if v.key == "power.motors" else (v.lo, v.hi)
    pr = aeroopt.from_project(p)
    items = sg.configurations(p, pr)
    assert len(items) == 2 * 2                               # 2 hélices × 2 e 4 motores (na asa vão aos pares)
    assert {tuple(i.values) for i in items} == {("power.propeller", "power.motors")}
    pr.variable("power.motors").hi = 400
    with pytest.raises(ValueError):
        sg.configurations(p, pr)
    pr.variable("power.motors").hi = 4
    pr.variable("power.propeller").options = ["APC 99x1"]           # hélice que não existe: para antes de rodar
    with pytest.raises(ValueError, match="não existe"):
        sg.configurations(p, pr)


def test_score_inputs_split_payload_and_micro_score_in_core():
    d = dict(mtow=4.2, pv=1.6, m_bat=0.3, s_to=3.5, b=1.8, lapes=True, liquid=True)
    r = sg.inputs(d)
    assert r["c_lapes"] == r["c_liq"] == pytest.approx(1.3) and r["ee"] == pytest.approx(2.6 / 1.6)
    assert sg.inputs({**d, "liquid": False})["c_liq"] == 0.0
    it = StageItem("a", data=dict(d))
    sg.Score(aeroopt.scoring.scoring_for("sae_br_2026_micro")).run([it])
    assert it.data["valido"] and it.data["nota"] > 0
    assert it.data["termos"]["cp_m"] == pytest.approx(2.6)
    wide = StageItem("b", data=dict(d, b=2.4))                   # 2,4 m: a fórmula dá negativo e o voo não vale
    sg.Score(aeroopt.scoring.scoring_for("sae_br_2026_micro")).run([wide])
    assert not wide.data["valido"] and wide.data["nota"] == 0.0 and wide.data["nota_formula"] < 0
    from aeroopt.generations import fitness
    r_ok, r_bad = sg.row(it), sg.row(wide)
    assert fitness(r_bad) == pytest.approx(wide.data["nota_formula"] - 1e9) and fitness(r_ok) > fitness(r_bad)


def test_staged_solver_sizes_surfaces_by_takeoff():
    """só a envergadura livre: a busca mexe nela e devolve o maior MTOW viável; o projeto do usuário não muda"""
    p = _project()
    before = copy.deepcopy(p)
    pr = aeroopt.from_project(p)
    pr.variable("wing.span").lo, pr.variable("wing.span").hi = 1.8, 3.0
    pr.isolate("wing.span")
    seen = []
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=3, geometry=False),
                                progress=lambda f, t: seen.append((f, t)))
    (row,) = res.rows
    spans = [h["values"]["wing.span"] for h in row["history"]]
    assert len(set(spans)) == 3                              # a busca andou na envergadura
    assert row["alive"] and row["nota"] == row["mtow"] == res.best["nota"]   # objetivo simples: o MTOW
    assert row["mtow"] == max(h["mtow"] for h in row["history"] if h["ok"])
    assert res.names["etapas"] == [("voa", 1, 1), ("superfícies", 1, 1), ("nota", 1, 1)]
    assert seen[-1][0] == pytest.approx(1.0)
    assert p.wing_draft.span == before.wing_draft.span and p.variables == before.variables


def test_six_dof_stage_gives_takeoff_mtow():
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, evals=1, geometry=False))
    (row,) = res.rows
    assert math.isfinite(row["mtow6"]) and row["inputs"]["mtow"] == row["mtow6"]


def test_categories_build_each_kind_of_aircraft():
    """cada categoria monta o avião dela pela sprint; as categorias escolhidas viram um eixo das configurações"""
    from aeroopt import categories as cat
    from aerosim.design import power as pw
    p = _project()
    surfaces = {}
    for c in ("asa baixa", "biplano", "tandem", "asa voadora", "cauda em V"):
        q, cand = sg.candidate(p, {cat.KEY: c})
        ac, _ = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
        surfaces[c] = [s.role for s in ac.surfaces]
    assert surfaces["asa voadora"].count("wing") == 1 and "htail" not in surfaces["asa voadora"]
    assert surfaces["biplano"].count("wing") == 2 and "htail" in surfaces["biplano"]
    assert surfaces["tandem"].count("wing") == 2 and "htail" not in surfaces["tandem"]
    q, _ = sg.candidate(p, {cat.KEY: "asa baixa"})
    assert q.rules.wing_z > 0 and p.rules.wing_z < 0              # o projeto do usuário não muda
    pr = aeroopt.from_project(p)
    pr.isolate("power.propeller")
    pr.variable("power.propeller").options = ["APC 15x8E", "Genérica 11x7"]
    pr.params["categorias"] = ["asa alta", "biplano", "asa voadora"]
    items = sg.configurations(p, pr)
    assert len(items) == 6 and items[0].name == "asa alta, hélice=APC 15x8E"
    assert cat.fields("monoplano") == cat.fields("asa alta")      # o monoplano sai com a asa alta
    assert "parasol" in cat.LEGACY and "parasol" not in cat.CATEGORIES
    pr.params["categorias"] = ["trimotor voador"]
    with pytest.raises(KeyError):
        sg.configurations(p, pr)


def test_geometry_stage_fixes_the_ground_and_stops_what_it_cannot_fix():
    """a EH deste avião raspa o chão girado 12°: a etapa geometria desce o trem e a configuração segue, e cada ponto
    da busca também passa pela geometria. Peça solta (pedida uma peça só) a geometria ainda não conserta: para ali"""
    from aerosim.interfaces.geometry import GeometryParams
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2))
    (row,) = res.rows
    assert row["alive"] and res.names["etapas"][0] == ("geometria", 1, 1)
    assert row["values"][sg.GEAR_KEY] > 0.1 and all(h["ok"] or "geometria" not in h["why"] for h in row["history"])
    pr.params["categorias"] = ["tandem"]                          # o montador ainda não põe o tubo entre as asas
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2,
                                                       geometry=GeometryParams(connected=True)))
    (row,) = res.rows
    assert not row["alive"] and row["stage"] == "geometria" and "soltas" in row["why"]


@pytest.mark.parametrize("method", ["gerações", "cma-es", "de"])
def test_surfaces_by_generations_keeps_the_budget_and_never_loses_the_start(method):
    """as gerações e o CMA-ES nas contínuas: o primeiro ponto é o avião como está, o total de pontos é o pedido e o
    melhor que sai não perde para o ponto de partida"""
    p = _project()
    pr = aeroopt.from_project(p)
    pr.variable("wing.span").lo, pr.variable("wing.span").hi = 1.8, 3.0
    pr.isolate("wing.span")
    ev = sg.StagedEvaluator(p, workers=1, six_dof=False, evals=9, geometry=False, surfaces=method)
    (row,) = sg.StagedSolver().run(pr, ev).rows
    h = row["history"]
    # o CMA-ES pode parar antes: com σ abaixo do passo do campo os pontos se repetem (convergiu)
    assert len(h) <= 9 and (len(h) == 9 or method in ("cma-es", "de")) and len({x["values"]["wing.span"] for x in h}) > 3
    assert all(1.8 <= x["values"]["wing.span"] <= 3.0 for x in h)
    assert row["mtow"] == max(x["mtow"] for x in h if x["ok"]) >= (h[0]["mtow"] if h[0]["ok"] else -1)
    again = sg.StagedSolver().run(pr, ev).rows[0]                    # a semente é o nome: mesma busca
    assert [x["values"] for x in again["history"]] == [x["values"] for x in h]
    with pytest.raises(ValueError, match="desconhecido"):
        sg.SurfaceSizing(p, pr, method="nenhum")


def test_geometry_stage_lowers_the_gear_instead_of_rejecting():
    """a cauda que bate no chão na rotação não reprova: o núcleo diz quanto descer as rodas, a etapa desce e confere
    de novo, e a altura do trem segue com a configuração (as superfícies e o 6GDL usam o mesmo trem)"""
    from aerosim.interfaces.geometry import GeometryParams
    from aerosim.interfaces.optim import StageItem
    p = _project()
    st = sg.GeometryStage(p, GeometryParams(rotation=20.0, connected=False))
    it = st.one(StageItem(name="a", values={}))
    h = it.values[sg.GEAR_KEY]
    assert it.data["geometria"]["gear_raise"] > 0.01 and h > 0.1
    assert all(x >= 0 for _, x in it.data["geometria"]["ground"])
    q, cand = sg.candidate(p, it.values)
    ac, _ = sg.pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
    assert ac.gear.main_z == pytest.approx(h) and sg.geometry_check(ac, GeometryParams(rotation=20.0, connected=False)).ok
    q, cand = sg.candidate(p, {})                                   # sem a altura: o trem de sempre (bit a bit)
    ac0, _ = sg.pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
    assert ac0.gear.main_z < h and ac.gear.steer_z - ac0.gear.steer_z == pytest.approx(h - ac0.gear.main_z)


def test_stability_makes_dihedral_count():
    """a corrida de decolagem não vê o diedro; a restrição de estabilidade vê: com anedro o C_lβ fica positivo e o
    ponto não fecha, com diedro passa. Desligada (o padrão), nada muda"""
    import pickle
    p = _project()
    pr = aeroopt.from_project(p)
    on = sg.SurfaceSizing(p, pr, stability=sg.StabilityParams(level=3))
    off = sg.SurfaceSizing(p, pr)
    neg, pos = on.point({"wing.dihedral": -6.0}), on.point({"wing.dihedral": 6.0})
    assert neg["mtow"] == pytest.approx(pos["mtow"])                       # a pista não muda
    assert not neg["ok"] and "C_lβ" in neg["why"] and neg["stab"]["Clb"] > 0
    assert pos["stab"]["Clb"] < 0 and pos["stab"]["Cnb"] > 0 and ("C_lβ" not in pos["why"])
    assert off.point({"wing.dihedral": -6.0})["stab"] == {}
    assert pickle.loads(pickle.dumps(on))._backend is None


def test_area_says_where_the_configuration_stopped():
    assert sg.area(dict(alive=False, why="geometria: EH bate no chão na rotação")) == "geometria"
    assert sg.area(dict(alive=False, why="precisa de 0.05 kg de lastro de equilíbrio")) == "equilíbrio"
    assert sg.area(dict(alive=False, why="estabilidade: instável direcional")) == "estabilidade"
    assert sg.area(dict(alive=False, why="não decola na pista")) == "desempenho"
    assert sg.area(dict(alive=False, why="não decola na pista; precisa de 0.07 kg de lastro")) == "equilíbrio + desempenho"
    assert sg.area(dict(alive=True, nota=90.0, valido=True)) == "nota"
    assert sg.area(dict(alive=True, nota=math.nan, stage="superfícies")) == "superfícies"


@pytest.mark.parametrize("method", ["buscar", "cma-es", "de"])
def test_fly_stage_finds_a_point_that_flies_before_performance(method):
    """a configuração que não equilibra como está (bateria não cabe, precisa de lastro) não morre: a etapa voa
    procura nas contínuas o ponto que viola menos até achar um que voa, e as superfícies partem dele"""
    from aerosim.interfaces.optim import StageItem
    from aeroopt.gui import example_project
    p, pr = example_project()
    pr.variable("wing.area").lo, pr.variable("wing.area").hi = 0.4, 0.6
    st = sg.FlightCheck(p, pr, evals=24, method=method)
    start = st.point({})
    assert not start["ok"] and start["viol"] > 0 and "lastro" in start["why"]
    it = st.one(StageItem(name="a", values={}))
    h = it.data["voa"]["history"]
    assert h[-1]["ok"] and len(h) <= 24 and it.data["voa"]["viol"] == 0
    assert st.point(it.values)["ok"]
    assert sg.FlightCheck(p, pr, method="conferir").point({})["viol"] == start["viol"]
    with pytest.raises(ValueError, match="lastro"):
        sg.FlightCheck(p, pr, method="conferir").one(StageItem(name="b", values={}))


def test_cma_es_search_learns_coupled_variables():
    """o CMA-ES do núcleo pelo contrato das buscas (`_cma_search`): fica na faixa, cai no passo, respeita o total e,
    com folga de avaliações, chega ao máximo de uma elipse girada (as variáveis acopladas, como envergadura e área),
    onde as gerações, que andam gene por gene, ficam ordens de grandeza atrás com o mesmo total"""
    import numpy as np
    free = [(f"v{i}", 0.0, 10.0) for i in range(4)]

    def point(y):
        z = np.cumsum([y[f"v{i}"] / 10 - 0.7 for i in range(4)])
        return dict(values=dict(y), ok=True, why="", mtow=-float(sum(10 ** i * z[i] ** 2 for i in range(4))), viol=0.0)
    x = {k: 2.0 for k, _, _ in free}
    start, hist = point(x), []
    x, best = sg._cma_search(free, x, start, point, 1200, hist, seed=3)
    assert len(hist) <= 1200 and all(0 <= v <= 10 for h in hist for v in h["values"].values())
    _, ga = sg._real_search(free, {k: 2.0 for k, _, _ in free}, start, point, 1200, [], seed=3)
    assert best["mtow"] > -1e-6 and ga["mtow"] < 1e3 * best["mtow"]
    again = []
    sg._cma_search(free, {k: 2.0 for k, _, _ in free}, start, point, 1200, again, seed=3)
    assert [h["values"] for h in again] == [h["values"] for h in hist]


def test_differential_evolution_search_keeps_the_contract():
    """a evolução diferencial do núcleo pelo contrato das buscas (`_de_search`): fica na faixa, cai no passo, respeita
    o total, não perde para o ponto de partida, repete a busca com a mesma semente e, na mesma elipse girada, chega
    mais perto do máximo que as gerações com o mesmo total"""
    import numpy as np
    free = [(f"v{i}", 0.0, 10.0) for i in range(4)]

    def point(y):
        z = np.cumsum([y[f"v{i}"] / 10 - 0.7 for i in range(4)])
        return dict(values=dict(y), ok=True, why="", mtow=-float(sum(10 ** i * z[i] ** 2 for i in range(4))), viol=0.0)
    x = {k: 2.0 for k, _, _ in free}
    start, hist = point(x), []
    x, best = sg._de_search(free, x, start, point, 1200, hist, seed=3)
    assert len(hist) <= 1200 and all(0 <= v <= 10 for h in hist for v in h["values"].values())
    _, ga = sg._real_search(free, {k: 2.0 for k, _, _ in free}, start, point, 1200, [], seed=3)
    assert best["mtow"] >= start["mtow"] and best["mtow"] > ga["mtow"]
    again = []
    sg._de_search(free, {k: 2.0 for k, _, _ in free}, start, point, 1200, again, seed=3)
    assert [h["values"] for h in again] == [h["values"] for h in hist]


def test_flight_check_chooses_the_tail_and_changes_the_individual():
    """com caudas pedidas, a etapa voa (E&C) testa cada uma na asa da configuração e fica com a que voa e decola na
    pista com a maior carga paga; o indivíduo passa a ter a cauda. Tandem e asa voadora definem a cauda e ficam como
    estão"""
    from aeroopt import categories as cat
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    pr.params["categorias"] = ["monoplano", "asa voadora"]
    pr.params["etapas"] = {"caudas": list(sg.TAILS)}
    fc = sg.FlightCheck(p, pr, evals=2, tails=pr.params["etapas"]["caudas"])
    mono, flying = sg.configurations(p, pr)
    assert fc.chooses_tail(mono) and not fc.chooses_tail(flying)
    out = fc.one(mono)
    tried = out.data["caudas"]
    assert list(tried) == list(sg.TAILS) and out.values[sg.TAIL_KEY] in sg.TAILS
    up = [t for t, d in tried.items() if d["ok"] and math.isfinite(d["cp"])]   # voam e decolam na pista
    assert up and out.values[sg.TAIL_KEY] == max(up, key=lambda t: (tried[t]["cp"], -sg.TAILS.index(t)))
    assert sg.TAIL_KEY not in fc.one(flying).values
    assert "cauda em V" not in cat.CATEGORIES and "cauda em V" in cat.LEGACY
    with pytest.raises(ValueError):
        sg.FlightCheck(p, pr, tails=["em T"])
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2))   # pelo problema
    row = next(r for r in res.rows if r["values"][cat.KEY] == "monoplano")
    assert row["values"].get(sg.TAIL_KEY) == out.values[sg.TAIL_KEY]


def test_core_rotation_agrees_with_the_sprint_on_a_tail_and_catches_the_flying_wing_elevon():
    """a rotação pelo núcleo (a conta da E&C com os comandos): no monoplano bate com a da sprint (mesmos termos,
    só C_m e C_L do núcleo); na asa voadora com elevon na envergadura toda a sprint diz que roda antes de sair do
    chão e o núcleo não, que é o que a decolagem 6GDL mostra (ela bate na pista)"""
    from aeroopt.gui import example_project
    from aerosim.backend.zig import ZigBackend
    from aerosim.design import power as pw
    p, _ = example_project()
    be = ZigBackend()

    def both(values):
        q, cand = sg.candidate(p, values)
        ac, asm = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
        tr = sg.core_rotation(ac, asm, q.rules, q.requirements.rho, be)
        return asm["trim"]["V_rot"], tr["V_rot"], tr["V_lof"]

    vs, vc, _ = both({"categoria": "monoplano"})
    assert vc == pytest.approx(vs, rel=0.1)
    vs, vc, vl = both({"categoria": "asa voadora", "power.propeller": "Genérica 13x6.5", "wing.span": 1.58,
                       "wing.area": 0.6, "tail.aileron_start": 0.1, "tail.aileron_end": 0.99,
                       "tail.aileron_chord": 0.48, "rules.de_max": 20.0, "power.tilt": 4.5})
    assert vs < vl < vc


def test_flight_check_with_controls_adds_the_controls_of_the_kind_of_aircraft():
    from aeroopt.gui import example_project
    p, pr = example_project()
    fc = sg.FlightCheck(p, pr, evals=2, controls=True)
    keys = [k for k, _, _ in fc.free_for({"categoria": "asa voadora"})]
    assert "tail.aileron_chord" in keys and "tail.elevator" not in keys
    keys = [k for k, _, _ in fc.free_for({"categoria": "monoplano"})]
    assert "tail.elevator" in keys and "tail.aileron_chord" not in keys
    assert sg.FlightCheck(p, pr, evals=2).free_for({"categoria": "asa voadora"}) == fc.free
