"""Entrada padrão das análises de carga (aerosim/interfaces/loads.py): o adaptador do núcleo, e qualquer outro método
(aqui um "CFD" de mentira em triângulos com um campo próprio) alimentando os mesmos gráficos e a mesma vista 3D."""
import os

import numpy as np
import pytest

from aerosim.aero.load_plots import span_figure
from aerosim.aero.span_loads import LoadCase, compute, to_result
from aerosim.interfaces.loads import LoadResult, SpanDistribution, SurfaceField, VectorLayer
from aerosim.model import modifiers as mods
from aerosim.model.templates import conventional


def core_result(backend, slip=True):
    ac = conventional()
    if slip:
        ac.modifiers.append(mods.Modifier("esteira.disco"))
    r = compute(backend, ac, LoadCase(V=12))
    return ac, r, to_result(r, backend)


def test_adapter_matches_the_core(backend):
    ac, r, res = core_result(backend)
    for s in r.surfaces:
        d = res.distribution(s.name)
        assert d.integral("L") == pytest.approx(s.lift, rel=1e-12)
        assert np.allclose(d.fields["carga"], s.L / s.chord)          # carga alar local = sustentação por área
    f = res.field
    assert f.faces.shape == (sum(len(s.s) for s in r.surfaces), 4) and len(f.vertices) == 4 * len(f.faces)
    for k in ("carga", "alpha_ef", "V_rel", "cl"):
        assert f.fields[k].shape == (len(f.faces),)
    # a área de cada face é a da faixa (corda × largura)
    V = f.vertices[f.faces]
    area = 0.5 * np.linalg.norm(np.cross(V[:, 2] - V[:, 0], V[:, 1] - V[:, 3]), axis=1)
    S = np.concatenate([s.chord * s.width for s in r.surfaces])
    assert np.allclose(area, S, rtol=1e-6)
    assert len(f.tubes) == 1 and {"força", "velocidade induzida"} == {v.name for v in f.vectors}
    assert "V = 12" in res.meta["caso"]


def fake_cfd() -> LoadResult:
    """outro método: malha em triângulos, campo 'cp' que o núcleo não tem"""
    ys = np.linspace(-1, 1, 11)
    verts = np.array([[x, y, 0.0] for y in ys for x in (0.0, -0.3)])
    faces = []
    for i in range(len(ys) - 1):
        a, b, c, d = 2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2
        faces += [[a, b, c], [a, c, d]]
    faces = np.array(faces)
    n = len(faces)
    fld = SurfaceField(verts, faces, fields={"cp": np.linspace(-1, 0.5, n), "carga": np.full(n, 50.0)},
                       face_surface=np.array(["asa"] * n),
                       vectors=[VectorLayer("força", verts[:n], np.tile([0, 0, -1.0], (n, 1)), "N")])
    mid = 0.5 * (ys[1:] + ys[:-1])
    dist = SpanDistribution("asa", "wing", False, mid, np.diff(ys), {"carga": np.full(10, 50.0), "L": np.full(10, 15.0)})
    return LoadResult([dist], fld, dict(fonte="CFD de teste", caso="teste"))


def test_triangles_from_quads_and_tris():
    q = SurfaceField(np.zeros((4, 3)), np.array([[0, 1, 2, 3]]))
    tri, src = q.triangles()
    assert tri.shape == (2, 3) and list(src) == [0, 0]
    t = fake_cfd().field
    assert t.triangles()[0].shape == t.faces.shape


def test_plots_take_any_method(backend, tmp_path):
    _, _, res = core_result(backend)
    fig = span_figure([("núcleo", res), ("CFD de teste", fake_cfd())], fields=("carga", "L", "alpha_ef"))
    p = tmp_path / "f.png"
    fig.savefig(p)
    assert p.stat().st_size > 10000


def test_3d_view_takes_any_method(backend, tmp_path):
    QtWidgets = pytest.importorskip("PyQt6.QtWidgets")
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    from aerosim.gui.widgets.load_view import LoadView, face_colors
    ac, _, res = core_result(backend)
    v = LoadView()
    v.set_result(res, ac)
    names = [v.combo.itemData(i) for i in range(v.combo.count())]
    assert names[:3] == ["carga", "L", "alpha_ef"]
    v.set_field("alpha_ef")
    assert "ângulo de ataque" in v.legend.title and v.legend.lo == -v.legend.hi
    v.set_result(fake_cfd())                                            # outro método, campo próprio
    names = [v.combo.itemData(i) for i in range(v.combo.count())]
    assert "cp" in names and "carga" in names
    v.set_field("cp")
    assert v.legend.title == "cp"
    cols, lo, hi = face_colors(np.array([1.0, 2.0, np.nan]), signed=False)
    assert cols.shape == (3, 4) and (lo, hi) == (1.0, 2.0)
    app.processEvents()
