"""Decolagem para a competição: só dois critérios, os da pista.

  x_warning  comprimento de pista: a aeronave tem de "decolar" antes dele
  z_warning  altura que conta como decolado, medida sobre a superfície de partida (chão ou mesa).
             z > 0: decolou quando as rodas passam dessa altura (n_dec = onde isso acontece).
             z ≤ 0 (mesa): decolou ao sair da borda e não pode afundar mais que |z| abaixo dela.
             Em qualquer caso, depois de sair do chão não pode descer abaixo de min(z, 0).

O comando de decolagem é o profundor (ou o elevon, numa asa voadora): no ponto de acionamento s
(posição na pista) ele vai para a deflexão de cabrar. O otimizador procura o s que deixa a maior folga
x_warning − n_dec, começando pela deflexão máxima (autopilot.de_max) e só usando uma menor se nenhuma
posição funcionar com a máxima. Se nada funcionar com o profundor como está na corrida (takeoff.de0),
tenta segurá-lo picando na corrida (25 % e 50 % do curso) — o que o piloto faz quando o avião quer sair
do chão antes da hora (motor inclinado, EH que cabra muito). Sem comando de arfagem não há o que
otimizar: a aeronave decola sozinha.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.features import features
from aerosim.model.mission import takeoff_runway

from .runner import Runner, Stop

LEVELS = (1.0, 0.75, 0.5, 0.3, 0.15)       # frações da deflexão máxima, da maior para a menor


@dataclass
class TakeoffResult:
    s: float                    # ponto de acionamento (m); nan sem comando de arfagem
    de: float                   # deflexão usada (graus, − cabra)
    n_dec: float                # onde "decolou" pelo critério (m); inf se não
    h_min: float                # menor altura sobre a superfície de partida depois de sair do chão (m)
    x_excess: float             # quanto passou do x_warning (0 se dentro)
    z_short: float              # quanto faltou de altura (0 se ok)
    ok: bool
    status: str
    events: dict = field(default_factory=dict)
    de0: float = float("nan")   # profundor na corrida até o acionamento (graus, + pica); nan: o do avião

    @property
    def margin(self) -> float:
        return -math.inf if not self.ok else self.x_warning_margin

    x_warning_margin: float = -math.inf


def pitch_control(ac) -> str | None:
    """'profundor', 'elevon' (...) ou None"""
    f = features(ac)
    k = f.pitch_kind
    return {"elevator": "profundor", "elevon": "elevon", "ruddervator": "leme-profundor (cauda em V)"}.get(k, k or None)


def judge(log, ev, x_warning: float, z_warning: float) -> tuple[float, float, float, float, bool]:
    """(n_dec, h_min, x_excess, z_short, ok) a partir do registro de uma decolagem"""
    if log is None or not len(log):
        return math.inf, 0.0, math.inf, abs(z_warning), False
    h = np.asarray(log["h"], float)
    h = h - h[0]                                     # sobre a superfície de partida (repouso = 0)
    n = np.asarray(log["n"], float)
    t = np.asarray(log["t"], float)
    air = t >= ev["tLO"] if ev.get("tLO", -1) > 0 else np.zeros_like(t, bool)
    h_min = float(h[air].min()) if air.any() else 0.0
    floor = min(z_warning, 0.0)
    if z_warning > 0:
        up = np.where(h >= z_warning)[0]
        n_dec = float(n[up[0]]) if len(up) else math.inf
    else:
        n_dec = float(ev["nLO"]) if ev.get("tLO", -1) > 0 else math.inf
    z_short = max(0.0, floor - h_min) if air.any() else 0.0
    if z_warning > 0 and not math.isfinite(n_dec):
        z_short = max(z_short, z_warning - float(h.max()))
    x_excess = max(0.0, n_dec - x_warning)
    ok = math.isfinite(n_dec) and x_excess == 0.0 and z_short == 0.0
    return n_dec, h_min, x_excess, z_short, ok


def evaluate(backend, ac, s: float | None, de: float, x_warning: float, z_warning: float,
             overrides: dict | None = None, dtlog: float = 0.01, log: bool = False, de0: float | None = None):
    """uma decolagem com acionamento em s (None: sem comando), deflexão de (graus) e, se dado, o profundor
    de0 (graus) durante a corrida"""
    to = dict(sR=max(s, 1e-6) if s is not None else 1e9, VR=1e9, de1=math.radians(de),
              h_end=max(ac.takeoff.h_end, z_warning + 1.0))
    if de0 is not None and math.isfinite(de0):
        to["de0"] = math.radians(de0)
    over = dict(overrides or {})
    over.update(takeoff=dict(over.get("takeoff", {}), **to), tmax=over.get("tmax", 60.0), dtlog=dtlog)
    with Runner(backend, ac, takeoff_runway(h=max(15.0, to["h_end"] + 5), V=ac.mission.V0), over) as r:
        r.start_ground()
        o = r.run(Stop(takeoff=True), live=False)
        h0 = float(o.log["h"][0]) if len(o.log) else 0.0
        status = o.status.name
        if status == "COMPLETED":                 # decolar é continuar voando: mais 4 s depois de h_end
            o2 = r.run(Stop(t=r.session.time + 4.0), live=False)
            if o2.status.name == "CRASHED" or (len(o2.log) and float(o2.log["h"].min()) - h0 < max(z_warning, 0.0)):
                status = "CAIU DEPOIS DE DECOLAR"
    n_dec, h_min, xe, zs, ok = judge(o.log, o.events, x_warning, z_warning)
    ok = ok and status == "COMPLETED"
    res = TakeoffResult(float("nan") if s is None else s, de, n_dec, h_min, xe, zs, ok, status, o.events,
                        float("nan") if de0 is None else de0)
    res.x_warning_margin = x_warning - n_dec if ok else -math.inf
    return (res, o.log) if log else res


def optimize(backend, ac, x_warning: float, z_warning: float, parallel=None, overrides: dict | None = None,
             n_grid: int = 8, refine: int = 5) -> tuple[TakeoffResult, list[TakeoffResult]]:
    """melhor ponto de acionamento (e a maior deflexão que funciona); devolve (melhor, todos os testados)"""
    run = parallel or (lambda fn, items: [fn(i) for i in items])
    if pitch_control(ac) is None:
        r = evaluate(backend, ac, None, 0.0, x_warning, z_warning, overrides)
        return r, [r]
    dmax = ac.autopilot.de_max
    grid = np.linspace(0.0, max(x_warning, 5.0) * 0.95, n_grid)
    tried, best = [], None
    for hold in (None, 0.25 * dmax, 0.5 * dmax):     # profundor na corrida: o do avião; depois picando
        for lv in LEVELS:                             # da deflexão máxima para baixo: para na 1ª que passa
            rs = run(lambda s: evaluate(backend, ac, float(s), -lv * dmax, x_warning, z_warning, overrides,
                                        de0=hold), list(grid))
            tried += rs
            good = [r for r in rs if r.ok]
            if good:
                best = max(good, key=lambda r: r.x_warning_margin)
                break
        if best is not None:
            break
    if best is None:                                  # ninguém passa: o "menos ruim" (para o diagnóstico)
        best = min(tried, key=lambda r: (r.x_excess + 10 * r.z_short, r.n_dec))
        return best, tried
    # refina s (seção áurea) em volta do melhor, na mesma deflexão
    h = grid[1] - grid[0]
    a, b = max(0.0, best.s - h), best.s + h
    g = (math.sqrt(5) - 1) / 2
    hold = None if not math.isfinite(best.de0) else best.de0
    f = lambda s: evaluate(backend, ac, s, best.de, x_warning, z_warning, overrides, de0=hold)
    c, d = b - g * (b - a), a + g * (b - a)
    rc, rd = f(c), f(d)
    tried += [rc, rd]
    for _ in range(refine):
        if rc.x_warning_margin >= rd.x_warning_margin:
            b, d, rd = d, c, rc
            c = b - g * (b - a)
            rc = f(c)
            tried.append(rc)
        else:
            a, c, rc = c, d, rd
            d = a + g * (b - a)
            rd = f(d)
            tried.append(rd)
    best = max([best, rc, rd], key=lambda r: r.x_warning_margin)
    return best, tried
