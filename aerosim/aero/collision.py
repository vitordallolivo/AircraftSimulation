"""Quem o tubo de cada hélice atinge: superfícies (fração da área de cada uma) e objetos (fuselagem, tubos de cauda,
trem, motores... pela fração dos pontos da malha deles). A conta é do núcleo (`core/src/collision/collision.zig`):
aqui só se junta por componente.

O tubo pode ser o geométrico — um cilindro do raio da hélice, ao longo do eixo de tração, desde o disco — ou o da
esteira com uma tração (contrai como na teoria do momento, `modifiers/slipstream.zig`). Uma superfície acima ou abaixo
da linha de tração fica de fora ou só em parte dentro, e isso aparece na fração.

    hits = tube_hits(backend, ac)                       # cilindros do raio de cada hélice
    hits = tube_hits(backend, ac, V=12, thrust=[14.1])  # tubo da esteira com 14,1 N a 12 m/s
    for h in hits: print(h.prop, h.component, h.kind, h.fraction)
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

SURFACE_KINDS = {"wing", "htail", "vtail", "control", "device"}


@dataclass
class Hit:
    prop: str                  # motor
    component: str             # nome da superfície ou do objeto
    kind: str                  # "superfície" | "objeto"
    fraction: float            # superfície: fração da área dentro do tubo; objeto: fração dos pontos da malha


def tube_hits(backend, ac, V: float = 0.0, thrust: list[float] | None = None, length: float = 10.0,
              min_fraction: float = 1e-6) -> list[Hit]:
    """o que o tubo de cada motor ligado atinge (só o que tiver fração > min_fraction)"""
    from aerosim.backend.zig.translator import native_spec, panel_owners
    from aerosim.model.geometry import aircraft_meshes
    from aerosim.model.universal import build_model
    model = build_model(ac)
    owners = panel_owners(model)
    S = np.array([p["S"] for p in native_spec(model)["surf"]])
    units = [u for u in ac.propulsion if u.enabled]
    thrust = list(thrust) if thrust is not None else [0.0] * len(units)
    objects = []
    for key, parts in aircraft_meshes(ac).items():
        verts = [np.asarray(V_, float) for (V_, _F), kind in parts if kind not in SURFACE_KINDS and kind != "propdisk"]
        if verts:
            objects.append((key, np.vstack(verts)))
    out = []
    with backend.session_for(model) as s:
        for i, u in enumerate(units):
            frac = s.tube_panel_hits(i, thrust[i], V, length)
            for k, sm in enumerate(model.surfaces):
                rows = [j for j, (_, kk) in enumerate(owners) if kk == k and j < len(frac)]
                if rows and S[rows].sum() > 0:
                    f = float(np.sum(frac[rows] * S[rows]) / S[rows].sum())
                    if f > min_fraction:
                        out.append(Hit(u.name, sm.name, "superfície", f))
            for key, P in objects:
                if key == f"prop:{ac.propulsion.index(u)}":
                    continue                                   # o próprio motor
                f = float(np.mean(s.tube_point_hits(i, P, thrust[i], V, length)))
                if f > min_fraction:
                    out.append(Hit(u.name, key, "objeto", f))
    return out
