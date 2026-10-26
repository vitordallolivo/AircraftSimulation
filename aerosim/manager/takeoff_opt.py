"""Decolagem para a competição: os dois critérios da pista e um de voo.

  x_warning  comprimento de pista: a aeronave tem de "decolar" antes dele
  z_warning  altura que conta como decolado, medida sobre a superfície de partida (chão ou mesa).
             z > 0: decolou quando as rodas passam dessa altura (n_dec = onde isso acontece).
             z ≤ 0 (mesa): decolou ao sair da borda e não pode afundar mais que |z| abaixo dela.
             Em qualquer caso, depois de sair do chão não pode descer abaixo de min(z, 0).
  estol      até o fim da decolagem (h_end) nenhuma superfície chega ao C_Lmax (C_L/C_Lmax < 1, o `ratio_to` do
             núcleo). Uma decolagem que só passa a pista estolando não é decolagem: sem isto a busca preferia a
             rotação mais agressiva, que sai do chão cedo e estola logo depois. A proteção de α do piloto (núcleo,
             control/autopilot.zig) é sempre ligada, e o profundor não deixa α passar do alpha_max

O comando de decolagem é o profundor (ou o elevon, numa asa voadora): no ponto de acionamento s
(posição na pista) ele vai para a deflexão de cabrar. O otimizador procura o s que deixa a maior folga
x_warning − n_dec, começando pela deflexão máxima (autopilot.de_max) e só usando uma menor se nenhuma
posição funcionar com a máxima. Se nada funcionar com o profundor como está na corrida (takeoff.de0),
tenta segurá-lo picando na corrida (25 % e 50 % do curso) — o que o piloto faz quando o avião quer sair
do chão antes da hora (motor inclinado, EH que cabra muito). Sem comando de arfagem não há o que
otimizar: a aeronave decola sozinha.

Duas buscas do ponto de acionamento (`search`):
  grade     8 pontos iguais ao longo da pista, e uma seção áurea em volta do melhor (o de sempre).
  bisseção  primeiro a corrida sem acionar: onde o avião sai do chão sozinho (ou o fim da pista) é o acionamento mais
            tarde que faz sentido. Daí, bisseção em s com passos até `S_TOL`: se o avião passa do fim da pista sem
            decolar, aciona antes; se sai do chão e afunda (ou cai), aciona depois; se passa, tenta antes, para ganhar
            folga. O número de voos depende da faixa (log₂(faixa / S_TOL)), não de uma grade fixa, e a janela estreita
            que a grade pulava (o tandem que roda cedo demais) não escapa.
"""
from __future__ import annotations

import contextlib
import math
import threading
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.features import features
from aerosim.model.mission import takeoff_runway

from .runner import Runner, Stop

LEVELS = (1.0, 0.75, 0.5, 0.3, 0.15)       # frações da deflexão máxima, da maior para a menor
SEARCHES = ("grade", "bisseção")            # a busca do ponto de acionamento (o docstring do módulo)
S_TOL = 0.25                                # bisseção: para quando a faixa de s fica menor que isto (m)
STALL = 1.0                                 # C_L/C_Lmax (a superfície mais carregada) que reprova a decolagem


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


class _Runners:
    """sessões do núcleo configuradas uma vez para o avião e emprestadas a quem vai decolar (uma por decolagem ao
    mesmo tempo). Entre uma decolagem e outra só muda o comando de decolagem (`takeoff`), que o configure do núcleo
    não lê (core/src/sim/runner.zig, `configure`); o resto do spec é o mesmo. Então reaproveitar a sessão dá o mesmo
    resultado, bit a bit, que abrir uma nova, sem refazer a cada decolagem o `aero.init` (o pico de C_L de cada
    painel), que é a parte cara do configure. As sessões livres ficam numa fila, não presas à thread: cada chamada
    do `parallel` pode abrir threads novas, e o núcleo tem poucas vagas (`L.max_instances`)."""

    def __init__(self, backend, ac):
        self.backend, self.ac = backend, ac
        self._free: dict = {}
        self._open: list[Runner] = []
        self._lock = threading.Lock()

    @contextlib.contextmanager
    def borrow(self, key, mission, over: dict):
        with self._lock:
            free = self._free.setdefault(key, [])
            r = free.pop() if free else None
        if r is None:
            r = Runner(self.backend, self.ac, mission, over)
            with self._lock:
                self._open.append(r)
        else:
            r.overrides = dict(over)
            r.spec = self.backend.translator.to_native(r.model, mission=r.mission, overrides=r.overrides)
            r.session.set(takeoff=r.spec["takeoff"])
        try:
            yield r
        finally:
            with self._lock:
                self._free[key].append(r)

    def close(self) -> None:
        for r in self._open:
            r.close()
        self._open.clear()
        self._free.clear()


def evaluate(backend, ac, s: float | None, de: float, x_warning: float, z_warning: float,
             overrides: dict | None = None, dtlog: float = 0.01, log: bool = False, de0: float | None = None,
             runners: _Runners | None = None):
    """uma decolagem com acionamento em s (None: sem comando), deflexão de (graus) e, se dado, o profundor
    de0 (graus) durante a corrida. `runners`: sessões reaproveitadas (as do `optimize`); None: uma sessão nova"""
    to = dict(sR=max(s, 1e-6) if s is not None else 1e9, VR=1e9, de1=math.radians(de),
              h_end=max(ac.takeoff.h_end, z_warning + 1.0))
    if de0 is not None and math.isfinite(de0):
        to["de0"] = math.radians(de0)
    over = dict(overrides or {})
    over.update(takeoff=dict(over.get("takeoff", {}), **to), tmax=over.get("tmax", 60.0), dtlog=dtlog)
    h_mission = max(15.0, to["h_end"] + 5)
    mission = takeoff_runway(h=h_mission, V=ac.mission.V0)
    if runners is None:
        with Runner(backend, ac, mission, over) as r:
            o, status, h0 = _fly(r, z_warning)
    else:
        key = (h_mission, ac.mission.V0, tuple(sorted((k, repr(v)) for k, v in over.items() if k != "takeoff")))
        with runners.borrow(key, mission, over) as r:
            o, status, h0 = _fly(r, z_warning)
    n_dec, h_min, xe, zs, ok = judge(o.log, o.events, x_warning, z_warning)
    if status == "COMPLETED" and o.events.get("ratio_to", 0.0) >= STALL:
        status = "ESTOLOU NA DECOLAGEM"           # conta como "cedo demais" na bisseção (`_early`)
    ok = ok and status == "COMPLETED"
    res = TakeoffResult(float("nan") if s is None else s, de, n_dec, h_min, xe, zs, ok, status, o.events,
                        float("nan") if de0 is None else de0)
    res.x_warning_margin = x_warning - n_dec if ok else -math.inf
    return (res, o.log) if log else res


def _fly(r: Runner, z_warning: float):
    """corrida até decolar e mais 4 s de voo: (saída da corrida, situação, altura inicial)"""
    r.start_ground()
    o = r.run(Stop(takeoff=True), live=False)
    h0 = float(o.log["h"][0]) if len(o.log) else 0.0
    status = o.status.name
    if status == "COMPLETED":                 # decolar é continuar voando: mais 4 s depois de h_end
        o2 = r.run(Stop(t=r.session.time + 4.0), live=False)
        if o2.status.name == "CRASHED" or (len(o2.log) and float(o2.log["h"].min()) - h0 < max(z_warning, 0.0)):
            status = "CAIU DEPOIS DE DECOLAR"
    return o, status, h0


def optimize(backend, ac, x_warning: float, z_warning: float, parallel=None, overrides: dict | None = None,
             n_grid: int = 8, refine: int = 5, search: str = "grade",
             tol: float = 0.0) -> tuple[TakeoffResult, list[TakeoffResult]]:
    """melhor ponto de acionamento (e a maior deflexão que funciona); devolve (melhor, todos os testados). `tol`
    (fração do x_warning; só na bisseção, 0 = a busca de sempre): ver `_bisect`"""
    if search not in SEARCHES:
        raise ValueError(f"busca do acionamento desconhecida: {search} (há {', '.join(SEARCHES)})")
    runners = _Runners(backend, ac)       # sessões configuradas uma vez, emprestadas a cada decolagem
    try:
        if search == "bisseção":
            return _bisect(backend, ac, x_warning, z_warning, overrides, runners, tol)
        return _optimize(backend, ac, x_warning, z_warning, parallel, overrides, n_grid, refine, runners)
    finally:
        runners.close()


def _optimize(backend, ac, x_warning, z_warning, parallel, overrides, n_grid, refine, runners):
    run = parallel or (lambda fn, items: [fn(i) for i in items])
    if pitch_control(ac) is None:
        r = evaluate(backend, ac, None, 0.0, x_warning, z_warning, overrides, runners=runners)
        return r, [r]
    dmax = ac.autopilot.de_max
    grid = np.linspace(0.0, max(x_warning, 5.0) * 0.95, n_grid)
    tried, best = [], None
    for hold in (None, 0.25 * dmax, 0.5 * dmax):     # profundor na corrida: o do avião; depois picando
        for lv in LEVELS:                             # da deflexão máxima para baixo: para na 1ª que passa
            rs = run(lambda s: evaluate(backend, ac, float(s), -lv * dmax, x_warning, z_warning, overrides,
                                        de0=hold, runners=runners), list(grid))
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
    f = lambda s: evaluate(backend, ac, s, best.de, x_warning, z_warning, overrides, de0=hold, runners=runners)
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


def _early(r: TakeoffResult) -> bool:
    """acionou cedo demais: saiu do chão e afundou abaixo do permitido, estolou ou caiu depois de sair"""
    return r.z_short > 0 or r.status != "COMPLETED"


def _bisect(backend, ac, x_warning, z_warning, overrides, runners, tol: float = 0.0):
    """a busca "bisseção" (o docstring do módulo). Para cada profundor na corrida (o do avião; depois picando) e cada
    deflexão (da maior para a menor), como a grade: para na primeira que passa.

    Com `tol` > 0 (fração do x_warning) a busca aceita errar um pouco para gastar menos voos, em duas coisas. A
    bisseção em s para quando a faixa fica menor que tol × x_warning (e não menos que `S_TOL`). E a massa que não
    decola desiste cedo: se com o comando todo cabrando nenhum voo saiu do chão cedo demais (todos passaram do fim
    da pista sem decolar), uma deflexão menor ou o profundor picando na corrida só atrasam a rotação, e o resto das
    combinações não é tentado. É nessas massas que vai o grosso do tempo do MTOW: no monoplano da Regular 2026, 447
    dos 691 voos eram de "passou do fim sem decolar" """
    if pitch_control(ac) is None:
        r = evaluate(backend, ac, None, 0.0, x_warning, z_warning, overrides, runners=runners)
        return r, [r]
    dmax = ac.autopilot.de_max
    tried, best = [], None
    for hold in (None, 0.25 * dmax, 0.5 * dmax):
        free = evaluate(backend, ac, None, 0.0, x_warning, z_warning, overrides, de0=hold, runners=runners)
        tried.append(free)
        lof = free.events.get("nLO", math.inf) if free.events.get("tLO", -1) > 0 else math.inf
        top = min(lof, x_warning) if math.isfinite(lof) else x_warning     # acionar depois disso não adianta
        for lv in LEVELS:
            f = lambda s: evaluate(backend, ac, s, -lv * dmax, x_warning, z_warning, overrides, de0=hold,
                                   runners=runners)
            lo, hi, good, early = 0.0, top, None, False
            while hi - lo > max(S_TOL, tol * x_warning):
                r = f(0.5 * (lo + hi))
                tried.append(r)
                if r.ok:
                    good = r if good is None or r.x_warning_margin > good.x_warning_margin else good
                    hi = r.s                          # passa: tenta antes, para ganhar folga
                elif _early(r):
                    lo, early = r.s, True
                else:
                    hi = r.s
            if good is not None:
                best = good
                break
            if tol > 0 and not early:                 # nem todo cabrando sai do chão a tempo: o resto só atrasa
                break
        if best is not None or (tol > 0 and not early):
            break
    if best is None:
        best = min(tried, key=lambda r: (r.x_excess + 10 * r.z_short, r.n_dec))
    return best, tried
