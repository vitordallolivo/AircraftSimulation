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
    form = [q.key for q in stages.TailStage(ctx).form()]
    assert "config" in form and not any(k.startswith("wing2") for k in form)   # a Empenagem não tem segunda asa
    assert stages.TailStage(ctx).disabled() == ("wing",)
    wing.edit_grid("asas", "delete", 1)
    assert ctx.design.tail_draft.wing2 == "nenhuma"


def test_wing_configuration_is_kept_and_chosen_in_the_tail_stage(tmp_path):
    """'Guardar configuração' em Projetar guarda a tabela com um nome; a Empenagem escolhe entre as guardadas e a
    tabela como está, e mexer na tabela depois não muda a configuração escolhida"""
    from aerosim.design import store
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    wing.do_keep()
    wing.edit_grid("asas", "add", -1)
    wing.edit_grid("asas", "add", 0)
    wing.edit_grid("asas", "set", 1, "dx", 1.0)
    assert "guardada" in wing.act("config", "tandem")
    tail = stages.TailStage(ctx)
    assert tail.choices()["config"] == ("a tabela de Projetar", "tandem")
    assert ctx.design.tail_draft.config == "tandem" and ctx.design.tail_draft.wing2_dx == 1.0
    wing.edit_grid("asas", "set", 1, "dx", 0.0)
    wing.edit_grid("asas", "set", 1, "dz", 0.4)                 # agora um biplano na tabela
    assert ctx.design.tail_draft.wing2_dx == 1.0                # a Empenagem segue no tandem guardado
    tail.set({"config": "a tabela de Projetar"})
    assert (ctx.design.tail_draft.wing2_dx, ctx.design.tail_draft.wing2_dz) == (0.0, 0.4)
    again = store.load(ctx.folder)
    assert again.configs[0].name == "tandem" and again.configs[0].wings[1].dx == 1.0


def test_old_second_wing_becomes_a_configuration(tmp_path):
    """uma sprint de antes, com a segunda asa nos campos da Empenagem, abre com uma configuração de duas asas e o
    mesmo conjunto (as mesmas superfícies, no mesmo lugar)"""
    from aerosim.design import store
    from aerosim.model.serialize import to_dict
    ctx = _context(tmp_path)
    stages.WingStage(ctx).do_keep()
    t = ctx.design.tail_draft
    t.wing2, t.wing2_dx, t.wing2_dz, t.wing2_di = "a mesma asa", 0.0, 0.35, 1.0
    def surfaces():                                             # sem o id do par (sorteado a cada conta)
        return [{k: v for k, v in to_dict(x).items() if k != "group"}
                for x in stages.TailStage(ctx).compute().aircraft.surfaces]
    before = surfaces()
    ctx.save()
    again = store.load(ctx.folder)
    assert [c.name for c in again.configs] == ["configuração 1"] and again.tail_draft.config == "configuração 1"
    rows = again.configs[0].wings
    assert rows[1].wing == rows[0].wing and (rows[1].dz, rows[1].di) == (0.35, 1.0)
    ctx.design = again
    assert surfaces() == before


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


def test_wing_devices_table_puts_each_device_on_its_wing(tmp_path):
    """a tabela de dispositivos de Projetar: cada um (o `WingDevice` do modelo) preso a uma linha da tabela de asas;
    a vista 3D, a Empenagem e o conjunto guardado levam cada um na asa dele"""
    from aerosim.design import store
    ctx = _context(tmp_path)
    wing = stages.WingStage(ctx)
    wing.do_keep()
    wing.edit_grid("asas", "add", -1)
    wing.edit_grid("asas", "add", 0)
    wing.edit_grid("asas", "set", 1, "dz", 0.35)
    names = [g.name for g in wing.grids()]
    assert names[:2] == ["asas", "dispositivos"]
    wing.edit_grid("dispositivos", "add", -1)
    wing.edit_grid("dispositivos", "add", 0)
    wing.edit_grid("dispositivos", "set", 1, "wing", "2: asa 1")
    wing.edit_grid("dispositivos", "set", 1, "kind", "placa")
    wing.edit_grid("dispositivos", "set", 1, "height", 0.2)
    rows = [g for g in wing.grids() if g.name == "dispositivos"][0].rows
    assert [r[:2] for r in rows] == [["1: asa 1", "winglet"], ["2: asa 1", "placa"]]
    view = wing.compute().aircraft.surfaces
    assert [d.kind for d in view[0].devices] == ["winglet"] and [d.kind for d in view[1].devices] == ["placa"]
    ac = stages.TailStage(ctx).compute().aircraft
    wings = [s for s in ac.surfaces if s.role == "wing"]
    assert [d.kind for d in wings[0].devices] == ["winglet"] and wings[1].devices[0].height == 0.2
    stages.TailStage(ctx).do_keep()
    again = store.load(ctx.folder)
    assert again.sets[0].devices[1][0].kind == "placa" and again.wing_layout[1].devices[0].kind == "placa"


def test_controls_table_is_generic_and_the_rule_is_its_default(tmp_path):
    """a tabela de comandos da Empenagem: vazia vale a regra; 'da regra' mostra a regra como linhas e o conjunto
    sai igual; com linhas, ela manda em todas as superfícies (um profundor na asa da frente, à frente do CG, com
    arfagem −1). Os campos de uma configuração só (arfagem do tandem, onde vão as derivas) saíram do formulário"""
    from aerosim.model.serialize import to_dict
    ctx = _context(tmp_path)
    stages.WingStage(ctx).do_keep()
    tail = stages.TailStage(ctx)
    keys = [q.key for q in tail.form()]
    assert "tandem_pitch" not in keys and "tip_fin_where" not in keys and "controls" not in keys
    grid = tail.grids()[0]
    assert grid.name == "comandos" and grid.rows == []

    def controls():
        return [(s.name, to_dict(c)) for s in tail.compute().aircraft.surfaces for c in s.controls]
    before = controls()
    tail.edit_grid("comandos", "rule", -1)
    rows = tail.grids()[0].rows
    assert [r[:2] for r in rows] == [["asa", "aileron"], ["EH", "elevator"], ["EV", "rudder"]]
    assert rows[1][5:] == [1.0, 0.0, 0.0]
    assert [n for n, _ in controls()] == [n for n, _ in before]
    assert "elevator" in tail.disabled()
    tail.edit_grid("comandos", "add", 0)
    tail.edit_grid("comandos", "set", 3, "kind", "elevon")
    tail.edit_grid("comandos", "set", 3, "pitch", -1.0)
    wing = tail.compute().aircraft.surfaces[0]
    assert [c.gains for c in wing.controls] == [(0.0, 1.0, 0.0), (-1.0, 1.0, 0.0)]
    tail.edit_grid("comandos", "clear", -1)
    assert controls() == before


def test_requirements_tables_edit_constraints_and_variables(tmp_path):
    """a janela das condições traz as restrições e as variáveis como tabelas, como as abas da GUI PyQt: ligar,
    trocar a grandeza e o valor de uma restrição; 'calculado' e 'situação' vêm da última etapa que rodou; o modo,
    o valor e as opções de uma variável; 'Limites das restrições' leva a envergadura máxima para o máx."""
    ctx = _context(tmp_path)
    stages.WingStage(ctx).compute()
    req = stages.RequirementsStage(ctx)
    restrictions, variables = req.grids()
    assert [c.label for c in restrictions.columns] == ["ativa", "grandeza", "op.", "valor", "unid.", "calculado",
                                                       "situação"]
    span = next(r for r in restrictions.rows if r[1] == "envergadura")
    assert span[0] is True and span[5] != "—" and span[6] in ("✔ cumpre", "✖ não cumpre")
    row = restrictions.rows.index(span)
    req.edit_grid("restricoes", "set", row, "value", 1.0)
    req.edit_grid("restricoes", "set", row, "active", False)
    c = ctx.design.requirements.constraints[row]
    assert c.value == 1.0 and not c.active and req.grids()[0].rows[row][6] == "desligada"
    req.edit_grid("restricoes", "set", row, "active", True)
    count = len(ctx.design.requirements.constraints)
    req.edit_grid("restricoes", "add", -1)
    req.edit_grid("restricoes", "set", count, "key", "teto")
    assert ctx.design.requirements.constraints[count].key == "ceiling"
    req.edit_grid("restricoes", "delete", count)
    assert len(ctx.design.requirements.constraints) == count

    keys = [v.key for v in ctx.design.variables]
    span_row, motor_row = keys.index("wing.span"), keys.index("power.motor")
    assert variables.rows[motor_row][3] is None and variables.rows[span_row][5] is None
    req.edit_grid("variaveis", "set", span_row, "value", "1,8")
    assert ctx.design.wing_draft.span == 1.8
    req.edit_grid("variaveis", "bounds", -1)
    assert ctx.design.variables[span_row].hi == 1.0
    req.edit_grid("variaveis", "set", motor_row, "options", "A, B")
    var = ctx.design.variables[motor_row]
    assert var.options == ["A", "B"] and var.mode == "variável"


def test_use_in_performance_opens_and_asks_for_the_analysis(tmp_path):
    """'Usar em Desempenho →' salva e abre o avião como 'Mandar para a Montagem', e pede à tela a análise de
    Desempenho ("open@performance:"); 'Mandar' continua indo para a Montagem ("open:")"""
    from aerosim.data.projects import JsonProjectStore
    ctx = _context(tmp_path)
    ctx.projects = JsonProjectStore(str(tmp_path / "avioes"))
    stages.WingStage(ctx).do_keep()
    stages.TailStage(ctx).do_keep()
    power = stages.PowerStage(ctx)
    assert [a.key for a in power.actions()] == ["send", "perf"]
    sent, used = power.act("send", ""), power.act("perf", "")
    assert sent.startswith("open:") and used.startswith("open@performance:")
    path = used.split(":", 1)[1].split("|", 1)[0]
    assert path.endswith(".json") and (tmp_path / "avioes").is_dir()
