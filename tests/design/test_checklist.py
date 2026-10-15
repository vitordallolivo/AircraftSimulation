"""Lista de verificação antes de salvar (aerosim/design/checklist.py)."""
from aerosim.design import checklist as ck
from aerosim.design.project import DesignProject
from aerosim.model.templates import conventional, empty


def _by(checks, item):
    return next(c for c in checks if c.item == item)


def test_complete_aircraft_has_nothing_to_define():
    ac = conventional()
    ac.takeoff.sR = 5.0
    cs = ck.define_checks(ac)
    assert cs and not ck.pending(cs)


def test_missing_masses_are_listed():
    ac = conventional()
    ac.payload.enabled, ac.payload.mass = True, 0.0
    ac.tanks[0].volume = 0.0
    ac.ballast.enabled, ac.ballast.mass = True, 0.0
    cs = ck.define_checks(ac)
    assert _by(cs, "LAPES: massa").status == ck.FAIL
    assert _by(cs, f"{ac.tanks[0].name}: líquido").status == ck.FAIL
    assert _by(cs, "lastro: massa").status == ck.ATT
    assert all(c.fix for c in ck.pending(cs))                 # cada pendência diz o que fazer


def test_empty_aircraft_misses_wing_and_motor():
    cs = ck.define_checks(empty())
    assert _by(cs, "asa").status == ck.FAIL and _by(cs, "motores").status == ck.ATT


def test_values_mass_is_dry_plus_lapes_and_liquid():
    ac = conventional()
    v0 = ck.values(ac)
    ac.payload.mass += 1.0
    ac.tanks[0].volume += 0.5
    v1 = ck.values(ac)
    assert abs(v1["mass"] - v0["mass"] - 1.5) < 1e-9 and abs(v1["cp"] - v0["cp"] - 1.5) < 1e-9
    assert abs(v1["pv"] - v0["pv"]) < 1e-9


def test_project_constraints_and_requirements():
    p = DesignProject()
    ac = conventional()
    p.requirements.span_max = 2.0                              # a envergadura do avião é 2,5 m
    cs = ck.project_checks(ac, p)
    span = next(c for c in cs if c.item == "restrição: envergadura")
    assert span.status == ck.FAIL and span.group == ck.CONS
    stall = next(c for c in cs if c.item == "restrição: velocidade de estol")
    assert stall.status == ck.INFO                             # precisa de análise: só informa
    p.requirements.mass = 100.0
    assert next(c for c in ck.project_checks(ac, p) if c.group == ck.REQS).status == ck.ATT
    p.requirements.constraints = []
    p.requirements.mass = ck.values(ac)["mass"]
    assert not ck.pending(ck.project_checks(ac, p))


def test_no_project_only_define_group():
    assert {c.group for c in ck.aircraft_checklist(conventional(), None)} == {ck.DEFINE}
