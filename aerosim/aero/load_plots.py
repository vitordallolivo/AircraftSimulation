"""Gráficos de carga ao longo da envergadura a partir da entrada padrão (`aerosim.interfaces.loads.LoadResult`):
qualquer método que produza um LoadResult (núcleo por faixas, VLM, painéis, CFD) usa os mesmos gráficos.

    fig = span_figure([("sem esteira", r0), ("com esteira", r1)], fields=("carga", "alpha_ef", "V_rel"))
    fig.savefig("carga.png")
"""
from __future__ import annotations

from aerosim.interfaces.loads import LoadResult, label

ROLE_NAMES = {"wing": "asa", "htail": "EH", "vtail": "EV", "device": "dispositivo"}
STYLES = (("#1f4e8c", "-"), ("#d95f02", "--"), ("#2a9d3f", "-."), ("#7b3fa0", ":"))


def span_figure(results: list[tuple[str, LoadResult]], fields=("carga", "alpha_ef", "V_rel"), roles=None,
                shade: list[tuple[float, float]] | None = None, title: str = ""):
    """uma coluna por papel de superfície (asa, EH, EV...), uma linha por campo; um traço por resultado.
    `shade`: faixas de y a sombrear (ex.: discos das hélices)"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    roles = roles or [r for r in ROLE_NAMES if any(res.by_role(r) for _, res in results)]
    fig, ax = plt.subplots(len(fields), len(roles), figsize=(5.2 * len(roles), 3.1 * len(fields) + 0.6), dpi=100,
                           squeeze=False)
    for col, role in enumerate(roles):
        vertical = False
        for (lab, res), (c, ls) in zip(results, STYLES):
            ds = res.by_role(role)
            for d in ds:
                vertical = d.vertical
                tag = lab if len(ds) == 1 else f"{lab}: {d.surface}"
                for row, name in enumerate(fields):
                    if name in d.fields:
                        ax[row, col].plot(d.s, d.fields[name], color=c, ls=ls, lw=2, label=tag)
        for row, name in enumerate(fields):
            a = ax[row, col]
            a.set_title(f"{ROLE_NAMES.get(role, role)}: {label(name)}", fontsize=10)
            a.grid(alpha=0.3)
            if shade and not vertical:
                for y0, y1 in shade:
                    a.axvspan(y0, y1, color="#999999", alpha=0.15)
        ax[-1, col].set_xlabel("altura (m, + para cima)" if vertical else "y (m) — envergadura (+ direita)")
        ax[0, col].legend(fontsize=8)
    if title:
        fig.suptitle(title, fontsize=10)
    fig.tight_layout(rect=(0, 0, 1, 0.96 if title else 1))
    return fig
