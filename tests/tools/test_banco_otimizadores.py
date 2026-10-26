"""tools/banco_otimizadores.py: o banco roda cada forma e cada método no sintético e resume por (forma, método)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))

import banco_otimizadores as bo  # noqa: E402


def test_bench_summarizes_every_shape_and_method(tmp_path, capsys):
    png = tmp_path / "b.png"
    assert bo.main(["--sementes", "2", "--avaliacoes", "24", "--variaveis", "2", "--metodos", "coordenadas,cma-es",
                    "--png", str(png)]) == 0
    out = capsys.readouterr().out
    assert "acoplada" in out and "multimodal" in out and "fração no fim" in out and png.exists()


def test_coordinates_reach_the_bowl_optimum_and_curves_never_go_down():
    rows = bo.run_surfaces(["tigela"], ["coordenadas", "gerações"], 2, 24, 2)
    assert [r["seed"] for r in rows if r["method"] == "coordenadas"] == [0]      # sem semente: uma rodada
    assert [r["seed"] for r in rows if r["method"] == "gerações"] == [0, 1]
    for r in rows:
        assert all(b >= a for a, b in zip(r["curve"], r["curve"][1:])) and r["final"] <= 1.0 + 1e-12
    s = {x["method"]: x for x in bo.summary(rows)}
    assert s["coordenadas"]["final"] >= bo.TARGET and s["coordenadas"]["reach"] <= 24
