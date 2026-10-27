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
    da busca também passa pela geometria. O tandem, com o tubo até a asa de trás e o pod até o CG, passa ligado (pedida
    uma peça só) e com as massas dentro"""
    from aerosim.interfaces.geometry import GeometryParams
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2))
    (row,) = res.rows
    assert row["alive"] and res.names["etapas"][0] == ("geometria", 1, 1)
    assert row["values"][sg.GEAR_KEY] > 0.1 and all(h["ok"] or "geometria" not in h["why"] for h in row["history"])
    pr.params["categorias"] = ["tandem"]                          # o tubo liga a asa de trás à fuselagem
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2,
                                                       geometry=GeometryParams(connected=True)))
    (row,) = res.rows
    assert row["stage"] != "geometria" and "soltas" not in row["why"] and "fora da geometria" not in row["why"]


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
    p, pr = example_project("NACA 2412")          # com o perfil de antes a bateria não cabe como está
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


def test_latin_hypercube_start_covers_every_slice_of_every_variable():
    """com `init="lhs"` a primeira geração (fora o x0) tem um ponto em cada fatia da faixa de cada variável, nas
    gerações e na evolução diferencial; o sorteio uniforme de sempre, com 9 pontos em 12 variáveis, deixa fatias
    vazias. O padrão continua o uniforme"""
    free = [(f"v{i}", 0.0, 9.0) for i in range(12)]

    def point(y):
        return dict(values=dict(y), ok=False, why="não fecha", mtow=math.nan, viol=1.0 + sum(y.values()))

    def empty(hist):
        first = [h["values"] for h in hist[:9]]
        return sum(9 - len({min(int(v[k]), 8) for v in first}) for k, _, _ in free)
    x = {k: 0.5 for k, _, _ in free}
    for search in (sg._real_search, sg._de_search):
        lhs, uni = [], []
        search(free, dict(x), point(x), point, 30, lhs, seed=5, init="lhs")
        search(free, dict(x), point(x), point, 30, uni, seed=5)
        assert empty(lhs) == 0 and empty(uni) > 0
    with pytest.raises(ValueError, match="início"):
        sg._real_search(free, dict(x), point(x), point, 30, [], seed=5, init="sobol")


def test_multi_start_keeps_searching_until_k_flying_points_far_apart():
    """a etapa voa para no primeiro ponto que fecha; com `Starts(k)` ela segue até ter k pontos que fecham, cada par
    afastado de pelo menos START_DIST da faixa, e devolve os k para a etapa escolher"""
    free = [(f"v{i}", 0.0, 10.0) for i in range(3)]

    def point(y):
        ok = y["v0"] > 5
        return dict(values=dict(y), ok=ok, why="" if ok else "não fecha", mtow=math.nan, viol=0.0 if ok else 6 - y["v0"])
    x = {k: 1.0 for k, _, _ in free}
    one = []
    sg._real_search(free, dict(x), point(x), point, 200, one, seed=2, stop_ok=True)
    assert sum(h["ok"] for h in one) == 1 and one[-1]["ok"]
    st, hist = sg.Starts(free, 3), []
    sg._real_search(free, dict(x), point(x), point, 200, hist, seed=2, stop_ok=True, init="lhs", starts=st)
    assert len(st.found) == 3 and all(r["ok"] for _, r in st.found)
    u = [[y[k] / 10 for k, _, _ in free] for y, _ in st.found]
    assert all(math.sqrt(sum((p - q) ** 2 for p, q in zip(u[i], u[j])) / 3) >= sg.START_DIST
               for i in range(3) for j in range(i))


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
    with pytest.raises(ValueError, match="rodar"):     # a asa voadora fica sem cauda e, com o elevon de hoje, não
        fc.one(flying)                                 # roda na pista (O20 no tracking)
    assert "cauda em V" not in cat.CATEGORIES and "cauda em V" in cat.LEGACY
    with pytest.raises(ValueError):
        sg.FlightCheck(p, pr, tails=["em T"])
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=2))   # pelo problema
    row = next(r for r in res.rows if r["values"][cat.KEY] == "monoplano")
    assert row["values"].get(sg.TAIL_KEY) == out.values[sg.TAIL_KEY]


def test_core_rotation_agrees_with_the_sprint_with_the_flap_moment():
    """a rotação pelo núcleo (a conta da E&C com os comandos): no monoplano bate com a da sprint (mesmos termos,
    só C_m e C_L do núcleo). Na asa voadora com elevon na envergadura toda, o núcleo só bate com a sprint com o
    momento próprio do comando ligado (modifiers/flapmoment.zig; sem ele o elevon cabra uns 2 vezes menos), e as
    duas dizem que ela não roda antes de sair do chão: a tração da hélice puxa o nariz para baixo (O20)"""
    from aeroopt.gui import example_project
    from aerosim.backend.zig import ZigBackend
    from aerosim.design import power as pw
    p, _ = example_project("NACA 2412")
    be = ZigBackend()

    def both(values):
        q, cand = sg.candidate(p, values)
        ac, asm = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
        tr = sg.core_rotation(ac, asm, q.rules, q.requirements.rho, be)
        return asm["trim"]["V_rot"], tr["V_rot"], tr["V_lof"]

    vs, vc, _ = both({"categoria": "monoplano"})
    assert vc == pytest.approx(vs, rel=0.1)
    fw = {"categoria": "asa voadora", "power.propeller": "Genérica 13x6.5", "wing.span": 1.58, "wing.area": 0.6,
          "tail.aileron_start": 0.1, "tail.aileron_end": 0.99, "tail.aileron_chord": 0.48, "rules.de_max": 20.0,
          "power.tilt": 4.5}
    vs, vc, vl = both(fw)
    vs2, vc2, _ = both({**fw, "tail.flap_moment": True})
    assert vs2 == pytest.approx(vs, rel=0.02) and vc2 < vc   # na sprint só a grade de V muda (V_lof trimado)
    assert vc2 == pytest.approx(vs, rel=0.1) and vl < vs


def test_flight_check_with_controls_adds_the_controls_of_the_kind_of_aircraft():
    from aeroopt.gui import example_project
    p, pr = example_project()
    fc = sg.FlightCheck(p, pr, evals=2, controls=True)
    keys = [k for k, _, _ in fc.free_for({"categoria": "asa voadora"})]
    assert "tail.aileron_chord" in keys and "tail.elevator" not in keys
    keys = [k for k, _, _ in fc.free_for({"categoria": "monoplano"})]
    assert "tail.elevator" in keys and "tail.aileron_chord" not in keys
    assert sg.FlightCheck(p, pr, evals=2).free_for({"categoria": "asa voadora"}) == fc.free
    # o tandem também é sem cauda, mas a asa de trás é a cauda: decalagem e recuo dela, nada de enflechamento
    assert fc.kind({"categoria": "tandem"}) == "tandem" and fc.kind({"categoria": "asa voadora"}) == "asa voadora"
    keys = [k for k, _, _ in fc.free_for({"categoria": "tandem"})]
    assert "tail.wing2_di" in keys and "tail.wing2_dx" in keys and "wing.sweep" not in keys


def test_flying_wing_flies_with_the_controls_of_e_and_c():
    """com os comandos, a E&C da asa voadora parte de uma asa enflechada com torção para baixo, põe um perfil
    simétrico na ponta (onde fica o elevon), a hélice atrás e o momento próprio dos comandos; a asa de alta
    sustentação do exemplo (S1223) passa a trimar e voa. Sem os comandos ela não roda na pista"""
    from aerosim.interfaces.optim import StageItem
    from aeroopt.gui import example_project
    p, pr = example_project()
    pr.isolate("wing.span")
    fc = sg.FlightCheck(p, pr, evals=4, controls=True)
    out = fc.one(StageItem(name="asa voadora", values={"categoria": "asa voadora"}))
    v = out.values
    assert v[sg.FLAP_KEY] and v[sg.LAYOUT_KEY] == sg.PUSHER and v[sg.TIP_KEY] == sg.elevon_airfoil(p, v)
    assert out.data["voa"]["viol"] == 0 and v["wing.sweep"] > 0 and v["wing.twist"] < 0
    with pytest.raises(ValueError):
        sg.FlightCheck(p, pr, evals=4).one(StageItem(name="b", values={"categoria": "asa voadora"}))


def test_e_and_c_rejects_what_the_6dof_would_reject():
    """duas coisas que a sprint deixava passar e só apareciam no 6GDL: pouco peso na bequilha (o avião senta para
    trás na corrida) e nenhuma estabilidade direcional (avião sem cauda, sem deriva na ponta)"""
    from aerosim.design import power as pw, tail as tl
    from aerosim.design.spec import Requirements
    from aerosim.design.wing import WingCandidate, WingParams
    from aerosim.design import airfoils as afm
    w = WingCandidate(WingParams(span=2.4, area=0.8), afm.AirfoilEntry(afm.from_naca("NACA 2412")))
    def viol(x_tdp=0.03, **tail):
        cand = pw.AircraftCandidate(pw.PowerParams(ground_pitch=3.0, x_tdp=x_tdp),
                                    tl.SetCandidate(tl.TailParams(**tail), w))
        _, asm = pw.assemble(cand, Requirements())
        return sg.violation(dict(asm=asm, cand=cand), rotation=True)[1]
    why = " ".join(viol(layout="sem cauda"))
    assert "bequilha leva só" in why and "estabilidade direcional" in why
    assert "estabilidade direcional" not in " ".join(viol(layout="sem cauda", tip_fin=0.25))
    # o mesmo avião com o trem mais atrás passa a levar peso na bequilha
    assert "bequilha" not in " ".join(viol(x_tdp=0.12, layout="sem cauda", tip_fin=0.25))


def test_ground_pitch_sets_the_nose_gear_and_the_6dof_starts_on_it():
    """a atitude no chão (`power.ground_pitch`) alonga a bequilha; a sprint corre com a asa nesse ângulo e a
    decolagem 6GDL começa parada nela (antes começava nivelada, a bequilha entrava no chão e o avião capotava)"""
    import numpy as np
    from aeroopt.gui import example_project
    from aerosim.backend.zig import ZigBackend
    from aerosim.design import power as pw
    from aerosim.manager import takeoff_opt as TO
    p, _ = example_project()
    v = {"categoria": "monoplano"}
    q, cand = sg.candidate(p, v)
    ac0, asm0 = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
    q, cand = sg.candidate(p, {**v, "power.ground_pitch": 6.0})
    ac, asm = pw.assemble(cand, q.requirements, q.rules, None, q.airfoil_map())
    assert pw.ground_pitch(ac0) == 0 and "CL_ground" not in asm0["trim"]
    assert pw.ground_pitch(ac) == pytest.approx(6.0) and asm["trim"]["CL_ground"] > asm0["set"]["CL_ground"]
    _, log = TO.evaluate(ZigBackend(), ac, 1.0, -10.0, 8.0, 1.0, log=True)
    assert np.degrees(float(log["theta"][0])) == pytest.approx(6.0, abs=0.3)


def test_payload_position_is_searched_by_the_flight_check_for_every_kind():
    """onde fica a carga paga é escolha do otimizador (O27): a busca dos comandos da E&C mexe em `power.x_payload`
    em todo tipo de avião, e o projeto parte da carga no CG"""
    from aerosim.design.power import PowerParams
    assert PowerParams().x_payload == 0.0
    for kind, ctl in sg.CONTROLS.items():
        assert "power.x_payload" in [k for k, _, _ in ctl], kind


def test_flight_check_with_controls_turns_on_the_dynamic_stability():
    """com os comandos, a E&C confere sempre os modos do núcleo (arfagem e látero-direcional, MIL-F-8785C): a conta
    estática da sprint deixava passar o tandem que, no 6GDL, guinava até cair (O28). Sem os comandos, como antes"""
    from aeroopt.gui import example_project
    p, pr = example_project()
    assert isinstance(sg.FlightCheck(p, pr, controls=True).stability, sg.StabilityParams)
    assert sg.FlightCheck(p, pr).stability is None


def _coded_case():
    """12 contínuas, duas com remédio na tabela do diagnóstico: o termo "cnb" só depende da deriva e o "lastro" só
    da posição da carga paga; as outras dez não mexem em nada"""
    free = [("tail.tip_fin", 0.0, 0.5), ("power.x_payload", -0.3, 0.3)] + [(f"v{i}", 0.0, 1.0) for i in range(10)]

    def point(y):
        t = {}
        if y["tail.tip_fin"] < 0.35:
            t["cnb"] = (0.35 - y["tail.tip_fin"]) / 0.1 + 0.1
        if abs(y["power.x_payload"] - 0.12) > 0.03:
            t["lastro"] = abs(y["power.x_payload"] - 0.12) / 0.05
        return dict(values=dict(y), ok=not t, why="; ".join(t), mtow=math.nan, viol=sum(t.values()), terms=t)
    return free, point


def test_diagnosis_maps_each_failure_to_the_free_variables_that_fix_it():
    """o diagnóstico liga o código do termo às variáveis que o consertam e ignora as que não estão livres; todo
    termo da violação tem código, e todo código tem remédio na tabela"""
    from aeroopt.diagnosis import REMEDIES, TableDiagnosis
    d = TableDiagnosis()
    assert d.remedies(["cnb", "lastro"], ["power.x_payload", "wing.span", "tail.tip_fin"]) == \
        ["tail.tip_fin", "power.x_payload"]
    assert d.remedies(["pista"], ["wing.span"]) == []
    import inspect
    src = inspect.getsource(sg.violation_terms)
    import re
    codes = set(re.findall(r'out\.append\(\("(\w+)"', src))
    assert codes and codes - {"pista"} <= set(REMEDIES)


@pytest.mark.parametrize("mode", ["reparo", "εde", "cultural", "lem", "diagnóstico"])
def test_guided_search_keeps_the_contract_and_finds_a_flying_point(mode):
    """a busca guiada pelo contrato das buscas: fica na faixa, respeita o total, repete com a mesma semente e acha
    um ponto que voa no caso com remédio"""
    from aeroopt.guided import guided_search
    free, point = _coded_case()
    x = {k: lo for k, lo, _ in free}
    hist, again = [], []
    _, best = guided_search(free, dict(x), point(x), point, 150, hist, seed=3, stop_ok=True, mode=mode)
    assert best["ok"] and len(hist) <= 150
    assert all(lo <= h["values"][k] <= hi for h in hist for k, lo, hi in free)
    guided_search(free, dict(x), point(x), point, 150, again, seed=3, stop_ok=True, mode=mode)
    assert [h["values"] for h in again] == [h["values"] for h in hist]
    with pytest.raises(ValueError, match="guiada"):
        guided_search(free, dict(x), point(x), point, 10, [], seed=3, mode="nada")


def test_failure_guided_search_needs_fewer_evaluations_than_plain_de():
    """com o motivo da falha a busca vai direto nas variáveis que consertam: o reparo por gradiente e o bandido do
    diagnóstico voam em todas as sementes, e com menos avaliações que a evolução diferencial de sempre, que muta as
    doze variáveis por igual"""
    from aeroopt.guided import guided_search
    free, point = _coded_case()
    x = {k: lo for k, lo, _ in free}

    def cost(run):
        out = []
        for s in range(8):
            h = []
            _, b = run(free, dict(x), point(x), point, 150, h, seed=s, stop_ok=True)
            out.append(len(h) if b["ok"] else 1000)
        return sum(out) / len(out)
    de = cost(sg._de_search)
    for mode in ("reparo", "diagnóstico"):
        assert cost(lambda *a, **k: guided_search(*a, **k, mode=mode)) < 0.7 * de


def test_tandem_terms_split_stagger_and_gap():
    """os termos só do tandem (`stages.tandem_terms`): o recuo da asa de trás fora de 3 a 5 cordas, o desnível
    acima de 1 corda e a parte da sustentação da asa da frente fora de 40 a 60 % no cruzeiro trimado. Com as asas
    iguais a da frente leva quase tudo; com a de trás maior e de perfil simétrico, menos (o C_m do perfil arqueado
    empurra a de trás para baixo). Sem segunda asa, nenhum termo"""
    from aerosim.backend.zig import ZigBackend
    from aerosim.design import power as pw
    from aeroopt.diagnosis import REMEDIES
    p = _project()
    be = ZigBackend()

    def terms(**kw):
        values = {"categoria": "tandem", **kw}
        pp, cand = sg.candidate(p, values)
        ac, _ = pw.assemble(cand, pp.requirements, pp.rules, None, pp.airfoil_map())
        return dict((c, v) for c, v, _ in sg.tandem_terms(ac, pp.requirements.V_cruise, be))
    near = terms(**{"tail.wing2_dx": 0.4, "tail.wing2_dz": 0.0})
    assert "escalonamento" in near and "vao" not in near
    assert "vao" in terms(**{"tail.wing2_dx": 1.6, "tail.wing2_dz": 0.6})
    same = terms(**{"tail.wing2_dx": 1.6, "tail.wing2_area": 1.0, "tail.wing2_airfoil": ""})
    big = terms(**{"tail.wing2_dx": 1.6, "tail.wing2_area": 2.0, "tail.wing2_airfoil": "NACA 0012"})
    assert same["divisao"] > big.get("divisao", 0.0)
    # a divisão muda com a velocidade (o C_m do perfil cresce com q): com várias, vale a pior
    pp, cand = sg.candidate(p, {"categoria": "tandem", "tail.wing2_dx": 1.6, "tail.wing2_area": 1.0,
                                "tail.wing2_airfoil": ""})
    ac, _ = pw.assemble(cand, pp.requirements, pp.rules, None, pp.airfoil_map())
    s8, s16 = sg.tandem_split(ac, 8.0, be), sg.tandem_split(ac, 16.0, be)
    assert s16 > s8
    both = dict((c, v) for c, v, _ in sg.tandem_terms(ac, [8.0, 16.0], be))
    assert both["divisao"] >= max(dict((c, v) for c, v, _ in sg.tandem_terms(ac, V, be)).get("divisao", 0.0)
                                  for V in (8.0, 16.0)) - 1e-12
    pp, cand = sg.candidate(p, {"categoria": "asa voadora"})
    ac, _ = pw.assemble(cand, pp.requirements, pp.rules, None, pp.airfoil_map())
    assert sg.tandem_terms(ac, 12.0, be) == []
    assert {"divisao", "escalonamento", "vao"} <= set(REMEDIES) and "tail.wing2_area" in REMEDIES["divisao"]
