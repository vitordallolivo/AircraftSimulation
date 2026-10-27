"""tools/metodos_voa.py: a comparação dos métodos da etapa voa roda no caso sintético e resume por método"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))

import metodos_voa as mv  # noqa: E402


def test_synthetic_comparison_summarizes_every_method(tmp_path, capsys):
    png = tmp_path / "m.png"
    assert mv.main(["--sintetico", "--sementes", "2", "--avaliacoes", "60", "--metodos", "de,diagnóstico",
                    "--png", str(png)]) == 0
    out = capsys.readouterr().out
    assert "diagnóstico" in out and "por sucesso" in out and png.exists()
    rows = mv.run_synthetic(["diagnóstico"], 2, 60)
    s = mv.summary(rows)[0]
    assert s["method"] == "diagnóstico" and s["rate"] == 1.0 and s["per_success"] < 60
