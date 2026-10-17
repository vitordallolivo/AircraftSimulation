"""Hélice no chão (T56): a folga da ponta da pá vem no registro (`hprop`) e nos eventos (`hpmin`); a pá tocar o chão
encerra o voo (`crashed`, `tprop`) só com `ac.sim.prop_strike = True` (desligado por padrão: regra 5 do CLAUDE.md;
o exemplo `flying_wing` começa com a pá dentro do chão e voa igual a antes)."""
from aerosim.backend.zig.translator import native_spec
from aerosim.model.templates import conventional, flying_wing


def _run(backend, ac):
    with backend.open_session() as s:
        s.configure(native_spec(ac))
        s.reset_ground()
        st, log = s.run()
        return st, log, s.events()


def test_clearance_at_rest_is_gear_height_minus_radius(backend):
    """parado no chão, a ponta da pá fica a (altura do trem − raio da hélice) do chão, menos o que as molas cedem e a
    atitude de repouso: na convencional, 0,22 m − 0,1905 m = 2,95 cm; o núcleo dá 2,5 cm"""
    ac = conventional()
    st, log, ev = _run(backend, ac)
    expected = ac.gear.main_z - 0.5 * ac.propulsion[0].propeller.D
    assert abs(float(log["hprop"][0]) - expected) < 0.01
    assert ev["tprop"] < 0 and ev["hpmin"] > 0                # voa sem bater a pá
    assert st.name != "CRASHED"


def test_prop_in_the_ground_fails_the_flight(backend):
    """asa voadora: hélice pusher de 15" com trem de 0,14 m: a pá já começa 5,5 cm dentro do chão"""
    ac = flying_wing()
    ac.sim.prop_strike = True
    st, log, ev = _run(backend, ac)
    assert st.name == "CRASHED"
    assert ev["tprop"] == 0.0 and ev["hpmin"] < 0


def test_prop_strike_is_off_by_default(backend):
    ac = flying_wing()
    assert ac.sim.prop_strike is False
    st, log, ev = _run(backend, ac)
    assert ev["tprop"] < 0                                    # não encerra
    assert ev["hpmin"] < 0                                    # mas registra a folga negativa
    assert len(log) > 10
