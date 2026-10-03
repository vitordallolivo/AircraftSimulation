"""Corrida orientada: começa (no chão, em voo ou de um checkpoint), roda até uma parada
em fatias (para a GUI desenhar em tempo real), salva checkpoints.

É a ferramenta que as simulações usam; fala com o núcleo só pela ISimSession.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from aerosim.interfaces.backend import ISimBackend, ISimSession, LogChunk, RunStatus
from aerosim.interfaces.simulation import RunContext
from aerosim.model.aircraft import Aircraft
from aerosim.model.universal import build_model
from aerosim.model.mission import Mission

from .checkpoints import Checkpoint, CheckpointStore


@dataclass
class Stop:
    """condição de parada (qualquer uma que acontecer primeiro)"""
    t: float | None = None            # tempo absoluto
    segment: int | None = None        # ao entrar no segmento k
    autopilot: bool = False           # quando o piloto automático liga
    takeoff: bool = False             # fim da decolagem (h_end)

    def overrides(self) -> dict:
        return dict(stop_t=self.t if self.t is not None else -1.0,
                    stop_seg=self.segment if self.segment is not None else -1,
                    stop_autop=int(self.autopilot), stop_takeoff=int(self.takeoff))


@dataclass
class RunOutput:
    status: RunStatus
    log: LogChunk
    events: dict[str, float] = field(default_factory=dict)
    t_end: float = 0.0


class Runner:
    def __init__(self, backend: ISimBackend, aircraft: Aircraft, mission: Mission | None = None,
                 overrides: dict | None = None, ctx: RunContext | None = None):
        self.backend = backend
        self.aircraft = aircraft
        self.mission = mission if mission is not None else aircraft.mission
        self.overrides = dict(overrides or {})
        self.ctx = ctx
        self.model = build_model(aircraft, self.mission)       # o modelo universal; o tradutor faz o resto
        self.session: ISimSession = backend.open_session()
        self.spec = backend.translator.to_native(self.model, mission=self.mission, overrides=self.overrides)
        self.session.configure(self.spec)

    # ------------------------------------------------------------------ início
    def start_ground(self) -> None:
        self.session.reset_ground()

    def start_air(self, segment: int = 0) -> None:
        self.session.reset_air(segment)

    def start_from(self, ck: Checkpoint | bytes) -> None:
        self.session.restore(ck.data if isinstance(ck, Checkpoint) else ck)

    # ------------------------------------------------------------------ corrida
    def run(self, stop: Stop | None = None, chunk: float = 1.0, live: bool = True, max_rows: int = 400_000,
            log: bool = True) -> RunOutput:
        """roda até a parada; com `live`, manda cada fatia para ctx.on_chunk"""
        stop = stop or Stop()
        spec = dict(self.spec, **stop.overrides())
        self.session.set(**stop.overrides())          # só as condições de parada (o resto já está lá)
        parts = []
        t_end_hint = stop.t if stop.t is not None else spec.get("tmax", 400.0)
        while True:
            if self.ctx:
                self.ctx.check()
            t_lim = self.session.time + chunk if (live and self.ctx) else math.inf
            st, part = self.session.run(t_lim, max_rows if log else 0)
            if log and len(part):
                parts.append(part)
                if live and self.ctx:
                    self.ctx.on_chunk(part)
            if self.ctx and t_end_hint:
                self.ctx.on_progress(min(self.session.time / t_end_hint, 1.0), f"t = {self.session.time:.1f} s")
            if not st.can_continue:
                break
        return RunOutput(st, LogChunk.concat(parts), self.session.events(), self.session.time)

    def checkpoint(self, name: str, store: CheckpointStore | None = None, **meta) -> Checkpoint:
        ck = Checkpoint(name, self.session.snapshot(), self.session.time, self.session.events(), meta)
        if store is not None:
            store.put(ck)
        elif self.ctx is not None:
            self.ctx.checkpoints.put(ck)
        return ck

    def reconfigure(self, mission: Mission | None = None, overrides: dict | None = None) -> None:
        """troca a missão/sobrescritas mantendo o estado (para continuar com outra configuração)"""
        if mission is not None:
            self.mission = mission
        if overrides is not None:
            self.overrides.update(overrides)
        self.spec = self.backend.translator.to_native(self.model, mission=self.mission, overrides=self.overrides)
        self.session.configure(self.spec)

    def close(self) -> None:
        self.session.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
