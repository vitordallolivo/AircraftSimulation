"""As etapas da sprint sem Qt (`aerosim/manager/stages.py`) e o formulário de dataclass (`aerosim/manager/forms.py`),
que a ponte usa para a tela em Zig: o formulário lê os mesmos campos da GUI PyQt, a edição volta para o rascunho, e
a conta é a mesma função de `aerosim.design.results`."""
from aerosim.design import results as R
from aerosim.design.project import DesignProject
from aerosim.manager import forms, stages
from aerosim.manager.manager import SimulationManager
from aerosim.model.catalog import builtin_catalog


def _context(tmp_path):
    return stages.Context(design=DesignProject(), catalog=builtin_catalog(), backend=SimulationManager().backend,
                          folder=str(tmp_path / "sprint"))


def test_form_reads_and_writes_the_draft(tmp_path):
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    specs = {p.key: p for p in wing.form()}
    assert specs["span"].kind == "float" and specs["span"].label == "envergadura" and specs["span"].unit == "m"
    assert specs["airfoil"].kind == "choice" and ctx.design.wing_draft.airfoil in specs["airfoil"].choices
    assert wing.set({"span": 2.2}) == ["span"]
    assert ctx.design.wing_draft.span == 2.2
    assert wing.set({"span": 2.2}) == []                         # o mesmo valor não muda nada


def test_optional_number_has_an_auto_box(tmp_path):
    entry = _context(tmp_path).design.airfoils[0]
    keys = [p.key for p in forms.specs(entry)]
    assert "airfoil.alpha0" + forms.AUTO in keys and "airfoil.alpha0" in keys
    forms.apply(entry, {"airfoil.alpha0" + forms.AUTO: False, "airfoil.alpha0": -2.5})
    assert entry.airfoil.alpha0 == -2.5
    forms.apply(entry, {"airfoil.alpha0" + forms.AUTO: True, "airfoil.alpha0": -2.5})
    assert entry.airfoil.alpha0 is None


def test_wing_stage_is_the_gui_computation(tmp_path):
    """o C_L × α da etapa Asa pela ponte é o de `results.wing_stage`, a mesma conta da página da GUI PyQt"""
    ctx = _context(tmp_path)
    outcome = stages.WingStage(ctx).compute()
    d = ctx.design
    _, direct, _ = R.wing_stage(d.draft_wing(), d.requirements, d.rules, [])
    assert outcome.result.summary == direct.summary


def test_stages_chain_keep_to_the_next(tmp_path):
    ctx = _context(tmp_path)
    assert "Guarde uma asa" in stages.TailStage(ctx).compute().message
    assert stages.WingStage(ctx).do_keep() == ctx.design.tail_draft.wing
    tail = stages.TailStage(ctx)
    assert tail.compute().plots
    assert tail.do_keep() == ctx.design.power_draft.set
    power = stages.PowerStage(ctx).compute()
    assert [t.title for t in power.tables] == ["Distribuição de massa", "Dimensões a partir do CG de projeto"]
    assert (tmp_path / "sprint").is_dir()                        # o projeto foi gravado a cada mudança


def test_airfoil_actions(tmp_path):
    ctx = _context(tmp_path)
    airfoils = stages.AirfoilStage(ctx)
    before = len(airfoils.kept())
    assert airfoils.act("naca", "0012").startswith("entrou")
    assert len(airfoils.kept()) == before + 1 and airfoils.draft().name == "NACA 0012"
    assert "já está" in airfoils.act("naca", "0012")
    airfoils.delete(len(airfoils.kept()) - 1)
    assert len(airfoils.kept()) == before


def test_partition_table_edits_the_draft(tmp_path):
    """a tabela de partições da etapa Asa (a mesma de `WingPage` na GUI PyQt): só aparece na planta por tabela, e cada
    edição volta para o rascunho e refaz os totais"""
    from aerosim.design import wing as wg
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    assert wing.grids() == []                                    # trapézio: sem tabela
    wing.set({"planform": wg.PLANFORMS[1]})
    grid, = wing.grids()
    assert [c.key for c in grid.columns] == ["span", "chord", "taper", "airfoil", "offset", "twist"]
    rows = len(grid.rows)
    wing.edit_grid(grid.name, "add", rows - 1)
    assert len(wing.grids()[0].rows) == rows + 1
    wing.edit_grid(grid.name, "set", 0, "span", 0.9)
    assert ctx.design.wing_draft.partitions[0].span == 0.9
    assert wing.grids()[0].note.startswith("envergadura total:")
    wing.edit_grid(grid.name, "delete", rows)
    assert len(wing.grids()[0].rows) == rows


def test_wing_outcome_has_a_view_and_the_neutral_point(tmp_path):
    from aerosim import bridge
    outcome = stages.WingStage(_context(tmp_path)).compute()
    view = bridge._view(outcome.aircraft, outcome.markers)
    assert view["meshes"] and "np_x" in view["markers"]


def test_wing_layout_table_feeds_the_tail_stage(tmp_path):
    """a tabela de asas de Projetar: quantas asas e onde, com base na primeira; a Empenagem pega a primeira e a
    segunda e deixa esses campos em cinza"""
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    wing.do_keep()
    wing.set({"name": "asa 2", "area": 1.2})
    wing.do_keep()
    grid = wing.grids()[0]
    assert grid.name == "asas" and grid.rows == []
    wing.edit_grid("asas", "add", -1)
    wing.edit_grid("asas", "add", 0)
    wing.edit_grid("asas", "set", 0, "wing", "asa 1")
    wing.edit_grid("asas", "set", 1, "wing", "asa 2")
    wing.edit_grid("asas", "set", 1, "dx", 1.4)
    wing.edit_grid("asas", "set", 0, "dx", 9.0)                 # a referência fica em Δ = 0
    rows = wing.grids()[0].rows
    assert rows[0][1] == 0.0 and rows[1][:2] == ["asa 2", 1.4]
    tail = ctx.design.tail_draft
    assert (tail.wing, tail.wing2, tail.wing2_dx) == ("asa 1", "asa 2", 1.4)
    assert "wing2_dx" in stages.TailStage(ctx).disabled()
    wing.edit_grid("asas", "delete", 1)
    assert ctx.design.tail_draft.wing2 == "nenhuma"


def test_wing_layout_three_wings_and_joined_tips(tmp_path):
    """da tabela de Projetar até a Empenagem: um triplano leva as três asas, o Δy e a placa das pontas ligadas
    (asa em caixa), e o conjunto guardado lê de volta igual"""
    from aerosim.design import store
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    wing.do_keep()
    for op, row, key, value in (("add", -1, "", None), ("add", 0, "", None), ("add", 1, "", None),
                                ("set", 1, "dz", 0.35), ("set", 1, "dy", 0.05), ("set", 1, "join", "sim"),
                                ("set", 2, "dz", 0.7)):
        wing.edit_grid("asas", op, row, key, value)
    assert len(wing.compute().aircraft.surfaces) == 3
    tail = stages.TailStage(ctx)
    ac = tail.compute().aircraft
    wings = [s for s in ac.surfaces if s.role == "wing"]
    assert len(wings) == 3 and abs(wings[1].y - 0.05) < 1e-9
    assert [d.kind for d in wings[0].devices] == ["winglet"] and abs(wings[0].devices[0].height - 0.35) < 1e-9
    tail.do_keep()
    again = store.load(ctx.folder)
    assert len(again.sets[0].more_wings) == 1 and again.sets[0].more_places[0].dz == 0.7
