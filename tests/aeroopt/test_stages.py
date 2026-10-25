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
    assert len(items) == 2 * 3                               # 2 hélices × 3 números de motores; a envergadura é contínua
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


def test_staged_solver_sizes_surfaces_by_takeoff():
    """só a envergadura livre: a busca mexe nela e devolve o maior MTOW viável; o projeto do usuário não muda"""
    p = _project()
    before = copy.deepcopy(p)
    pr = aeroopt.from_project(p)
    pr.variable("wing.span").lo, pr.variable("wing.span").hi = 1.8, 3.0
    pr.isolate("wing.span")
    seen = []
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, six_dof=False, evals=3),
                                progress=lambda f, t: seen.append((f, t)))
    (row,) = res.rows
    spans = [h["values"]["wing.span"] for h in row["history"]]
    assert len(set(spans)) == 3                              # a busca andou na envergadura
    assert row["alive"] and row["nota"] == row["mtow"] == res.best["nota"]   # objetivo simples: o MTOW
    assert row["mtow"] == max(h["mtow"] for h in row["history"] if h["ok"])
    assert res.names["etapas"] == [("superfícies", 1, 1), ("nota", 1, 1)]
    assert seen[-1][0] == pytest.approx(1.0)
    assert p.wing_draft.span == before.wing_draft.span and p.variables == before.variables


def test_six_dof_stage_gives_takeoff_mtow():
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    res = sg.StagedSolver().run(pr, sg.StagedEvaluator(p, workers=1, evals=1))
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
    assert len(items) == 6 and items[0].name == "asa alta, propeller=APC 15x8E"
    pr.params["categorias"] = ["trimotor voador"]
    with pytest.raises(KeyError):
        sg.configurations(p, pr)
