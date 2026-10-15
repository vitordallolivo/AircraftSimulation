"""SimResult ⇄ JSON (o que já rodou, guardado no projeto)."""
import json

import numpy as np
import pytest

from aerosim.interfaces.backend import LogChunk
from aerosim.interfaces.result_io import MAX_ROWS, result_from_dict, result_to_dict
from aerosim.interfaces.simulation import Check, SimResult


def test_round_trip_keeps_series_summary_checks_and_nan():
    n = 3 * MAX_ROWS
    t = np.linspace(0, 10, n)
    res = SimResult(log=LogChunk(columns={"t": t, "V": np.sin(t)}),
                    series={"a": dict(x=np.array([1.0, np.nan, 3.0]), y=np.array([1, 2, 3]), _color="#ff0000"),
                            "casos": dict(motivo=np.array(["ok", "estol", "ok"], dtype=object), V=np.array([1.0, 2.0, 3.0])),
                            "longa": dict(t=t, y=t ** 2)},
                    summary={"MTOW (kg)": np.float64(7.25), "texto": "abc", "inf": float("inf")},
                    events={"tLO": 3.5}, status="COMPLETED",
                    checks=[Check("ok", "item", "1", "≤ 2", "porque", "nada", "grupo", "fonte")])
    d = json.loads(json.dumps(result_to_dict(res)))
    r = result_from_dict(d)
    assert np.isnan(r.series["a"]["x"][1]) and r.series["a"]["y"].tolist() == [1, 2, 3]
    assert r.series["a"]["_color"] == "#ff0000" and list(r.series["casos"]["motivo"]) == ["ok", "estol", "ok"]
    assert r.summary["MTOW (kg)"] == pytest.approx(7.25) and r.summary["inf"] == float("inf")
    assert r.checks[0] == res.checks[0] and r.events == {"tLO": 3.5} and r.status == "COMPLETED"
    assert len(r.log) <= MAX_ROWS + 1 and r.log["t"][-1] == pytest.approx(10.0)          # reamostrado, fim junto
    L = r.series["longa"]
    # colunas com os mesmos índices; 6 algarismos em relação ao maior valor da coluna
    assert len(L["t"]) <= MAX_ROWS + 1 and np.allclose(L["y"], L["t"] ** 2, rtol=0, atol=1e-2)   # t também arredondado
