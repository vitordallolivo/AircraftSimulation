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
