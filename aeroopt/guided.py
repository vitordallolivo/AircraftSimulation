"""A busca guiada pela falha, do aeroopt: a etapa voa (E&C) usando o MOTIVO de cada avião não voar.

As buscas de `stages.py` (gerações, CMA-ES, evolução diferencial) só veem um número: o quanto o ponto viola. A E&C
sabe mais que isso. Cada termo da violação tem um código (`stages.violation_terms`), e o diagnóstico
(`diagnosis.TableDiagnosis`) liga cada código às variáveis que o consertam. Um tandem que guina até cair tem o
termo "cnb", e quem conserta é a deriva; um que precisa de lastro tem "lastro", e quem conserta é a posição da
carga paga. Mutar as outras quinze variáveis nesses casos é gastar avaliação.

A busca é a evolução diferencial de `stages._de_search` (a mesma população, o mesmo passo de cada campo, o mesmo
ponto repetido sem gastar avaliação), e cada filho sai de um de cinco operadores:

    de          o teste DE/rand/1/bin de sempre (Storn e Price, 1997)
    remédio     o mesmo teste, mas só nas variáveis que consertam a falha do pai; as outras ficam como estão.
                É a mutação dirigida pelo diagnóstico, a ideia do dono do repositório (sem fonte na literatura:
                a busca de 2026-10-26 não achou o mesmo operador, só parentes, como a mutação "por gradiente"
                do ε-DE)
    reparo      um passo de Newton nas restrições violadas, só nas variáveis do remédio, com o jacobiano por
                diferença para a frente: Δx = −Jᵀ (J Jᵀ + λ I)⁻¹ g (Chootinan e Chen, 2006). O ponto reparado
                volta para a população no lugar do pai (lamarckiano; Ong e Keane, "Meta-Lamarckian learning in
                memetic algorithms", IEEE TEC 8(2), 2004; a conferir no PDF). Gasta uma avaliação por variável
    cultural    um ponto sorteado no espaço normativo: a faixa de cada variável entre os melhores (Reynolds, 1994)
    lem         um ponto sorteado na regra que separa os melhores dos piores (Michalski, 2000)

O método diz quem escolhe o operador de cada filho:

    reparo       DE em todos e o reparo no que viola menos de cada geração
    εde          o mesmo, com a seleção ε-restrita no lugar da de Deb (Takahama e Sakai, 2006): até ε a
                 violação não decide, e o ε cai até zero na metade das gerações
    cultural     metade dos filhos do espaço normativo, metade DE
    lem          metade dos filhos da regra do LEM, metade DE
    diagnóstico  o bandido D-MAB escolhe entre os cinco, pela melhora que cada um já deu por avaliação gasta
                 (Da Costa, Fialho, Schoenauer e Sebag, 2008); o remédio só entra quando o pai viola um termo
                 que tem remédio livre, e o reparo só no que viola menos da geração

As contas (o passo do reparo, o ε, o bandido, as faixas) são do núcleo (core/src/optim/guided.zig); aqui fica o
laço. As fontes completas estão no docstring do módulo do núcleo.

    x, best = guided_search(free, x0, r0, point, evals=60, hist=[], seed=7, mode="diagnóstico")
"""
from __future__ import annotations

import math

import numpy as np

from . import inputs as inp
from .diagnosis import TableDiagnosis

GUIDED = {"reparo": "achar um ponto que voa (DE com o reparo por gradiente nas variáveis do remédio)",
          "εde": "achar um ponto que voa (DE ε-restrita com o reparo por gradiente)",
          "cultural": "achar um ponto que voa (DE com metade dos filhos no espaço dos melhores, algoritmo cultural)",
          "lem": "achar um ponto que voa (DE com metade dos filhos na regra que separa os melhores dos piores, LEM)",
          "diagnóstico": "achar um ponto que voa (o bandido escolhe o operador: DE, remédio da falha, reparo, "
                         "cultural ou LEM)"}
ARMS = ("de", "remédio", "reparo", "cultural", "lem")
DE_F, DE_CR = 0.5, 0.9          # os mesmos de stages._de_search (Storn e Price, 1997, seção 4; a conferir no PDF)
REPAIR_H = 0.05                 # passo da diferença para a frente, na faixa normalizada
REPAIR_MAX = 1.0                # o maior passo do reparo, na faixa normalizada: 1 é o passo de Newton inteiro, só
                                # cortado na caixa (com 0,3 o reparo levava quatro passos no caso sintético)
REPAIR_LAMBDA = 1e-3            # o λ de Levenberg do passo
REPAIR_DIMS = 4                 # quantas variáveis do remédio o reparo mexe (as primeiras da tabela)
EPS_THETA = 0.2                 # ε₀ é a violação do indivíduo na posição θ·NP da população inicial (Takahama e
EPS_CP = 5.0                    # Sakai, 2006, θ = 0,2 e cp de 2 a 10; a conferir no PDF)
NORM_FRAC, LEM_FRAC = 0.2, 0.3  # a fração dos melhores no espaço normativo e no H/L do LEM
UCB_C = 0.5                     # o peso da exploração do UCB1
PH_DELTA, PH_GAMMA = 0.05, 3.0  # a tolerância e o limiar do Page–Hinkley (a recompensa vai de 0 a 1)


def _rank(r: dict) -> tuple:
    from .stages import _rank as rank
    return rank(r)


def _reward(parent: dict, child: dict, cost: int) -> float:
    """a recompensa de um operador, de 0 a 1 por avaliação gasta: 1 se o filho fecha e o pai não, a fração da
    violação que caiu se os dois violam, 1 se os dois fecham e o filho ganha"""
    if child["ok"] and not parent["ok"]:
        r = 1.0
    elif not child["ok"] and not parent["ok"]:
        vp, vc = parent.get("viol", math.inf), child.get("viol", math.inf)
        r = max(0.0, (vp - vc) / vp) if math.isfinite(vp) and vp > 0 and math.isfinite(vc) else 0.0
    else:
        r = 1.0 if _rank(child) > _rank(parent) else 0.0
    return r / max(cost, 1)


def guided_search(free, x: dict, best: dict, point, evals: int, hist: list, seed: int, stop_ok: bool = False,
                  init: str = "uniforme", starts=None, mode: str = "diagnóstico", diagnosis=None):
    """o mesmo contrato de `stages._de_search`, com o operador de cada filho escolhido por `mode` (`GUIDED`)"""
    from aerosim.backend.zig import ZigBackend

    from .stages import _eval, _start_rows
    if mode not in GUIDED:
        raise ValueError(f"busca guiada desconhecida: {mode} (há {', '.join(GUIDED)})")
    be = ZigBackend()
    diagnosis = diagnosis or TableDiagnosis()
    keys = [k for k, _, _ in free]
    lo = np.array([a for _, a, _ in free])
    span = np.array([max(b - a, 1e-12) for _, a, b in free])
    steps = [(inp.get(k).step if inp.get(k) else 0.0) for k in keys]
    n = len(free)

    def snap(u) -> tuple:
        out = []
        for j in range(n):
            g = lo[j] + min(max(float(u[j]), 0.0), 1.0) * span[j]
            g = round(g / steps[j]) * steps[j] if steps[j] > 0 else g
            out.append(round(min(max(g, free[j][1]), free[j][2]), 6))
        return tuple(out)
    seen = {tuple(x[k] for k in keys): best}
    st = dict(x=x, best=best, done=False)

    def ev(u):
        """(u no passo do campo, resultado) de um ponto; resultado None quando acabaram as avaliações"""
        key = snap(u)
        uk = (np.array(key) - lo) / span
        r = seen.get(key)
        if r is None:
            if len(hist) >= evals or (stop_ok and st["done"]):
                return uk, None
            y = dict(zip(keys, key))
            r = seen[key] = point(y)
            hist.append(_eval(y, r))
            if _rank(r) > _rank(st["best"]):
                st["x"], st["best"] = y, r
            st["done"] = st["done"] or (starts.add(y, r) if starts else st["best"]["ok"])
        return uk, r

    def remedy_dims(r: dict) -> list[int]:
        terms = r.get("terms") or {}
        codes = sorted(terms, key=lambda c: -terms[c])
        return [keys.index(k) for k in diagnosis.remedies(codes, keys)]

    def repair(u, r: dict):
        """(ponto reparado, avaliações gastas no jacobiano) ou (None, gastas)"""
        terms = r.get("terms") or {}
        codes = sorted(terms, key=lambda c: -terms[c])[:16]
        dims = remedy_dims(r)[:REPAIR_DIMS]
        if r["ok"] or not codes or not dims:
            return None, 0
        g = np.array([terms[c] for c in codes])
        J = np.zeros((len(codes), len(dims)))
        used = 0
        for jj, d in enumerate(dims):
            v = u.copy()
            v[d] = u[d] + REPAIR_H if u[d] + REPAIR_H <= 1 else u[d] - REPAIR_H
            before = len(hist)
            vk, rv = ev(v)
            used += len(hist) - before
            if rv is None:
                return None, used
            h = vk[d] - u[d]
            if abs(h) < 1e-12:                       # o passo do campo engoliu a diferença
                continue
            tv = rv.get("terms") or {}
            J[:, jj] = [(tv.get(c, 0.0) - gk) / h for c, gk in zip(codes, g)]
        try:
            step = be.repair_step(J, g, REPAIR_LAMBDA)
        except ValueError:
            return None, used
        norm = float(np.linalg.norm(step))
        if norm > REPAIR_MAX:
            step *= REPAIR_MAX / norm
        v = u.copy()
        v[dims] = np.clip(u[dims] + step, 0.0, 1.0)
        return v, used

    np_ = max(4, min(10, evals // 3))
    pop = be.de_init([(x[k] - lo[j]) / span[j] for j, k in enumerate(keys)], np_, seed)
    rows = _start_rows(be, n, np_, seed, init)
    if rows is not None:
        pop[1:] = rows
    R = []
    for i in range(np_):
        pop[i], r = ev(pop[i])
        if r is None:
            return st["x"], st["best"]
        R.append(r)
    viols = sorted(r.get("viol", math.inf) if not r["ok"] else 0.0 for r in R)
    eps0 = viols[min(int(EPS_THETA * np_), np_ - 1)]
    eps0 = eps0 if math.isfinite(eps0) else 0.0
    gens = 4 * math.ceil(evals / np_) + 1
    bandit = be.bandit_init(len(ARMS)) if mode == "diagnóstico" else None

    def fitness(r):                               # a nota dentro de ε: o MTOW (NaN na E&C, que não corre a pista)
        m = r.get("mtow", math.nan)
        return m if r["ok"] and math.isfinite(m) else math.nan

    def wins(c: dict, p: dict, eps: float) -> bool:
        """o filho fica no lugar do pai (empate fica com o filho, como na DE)"""
        if mode == "εde":
            vc = 0.0 if c["ok"] else c.get("viol", math.inf)
            vp = 0.0 if p["ok"] else p.get("viol", math.inf)
            return not be.eps_worse(fitness(c), vc, fitness(p), vp, eps)
        return _rank(c) >= _rank(p)

    for gen in range(gens):
        if len(hist) >= evals or (stop_ok and st["done"]):
            break
        eps = be.eps_level(eps0, gen, 0.5 * gens, EPS_CP) if mode == "εde" else 0.0
        trial = be.de_trials(pop, DE_F, DE_CR, seed, gen)
        fit = np.array([(1e9 if r["ok"] else -r.get("viol", math.inf)) for r in R], float)
        fit[~np.isfinite(fit)] = np.nan
        boxes = {}
        if mode in ("cultural", "diagnóstico"):
            boxes["cultural"] = be.box_sample(*be.normative(pop, fit, NORM_FRAC), np_, seed, 2 * gen)
        if mode in ("lem", "diagnóstico"):
            boxes["lem"] = be.box_sample(*be.lem_box(pop, fit, LEM_FRAC), np_, seed, 2 * gen + 1)
        bad = [i for i in range(np_) if not R[i]["ok"]]
        # o reparo vai no que viola menos: perto da fronteira a aproximação linear vale. No pior (na asa voadora,
        # 100 kg de "lastro" sorteado longe de tudo) o passo de Newton não chega e gasta o jacobiano à toa
        fix = min(bad, key=lambda i: R[i].get("viol", math.inf)) if bad else -1
        for i in range(np_):
            if mode in ("reparo", "εde"):
                arm = "reparo" if i == fix else "de"
            elif mode in ("cultural", "lem"):
                arm = mode if i % 2 else "de"
            else:
                dims = remedy_dims(R[i]) if not R[i]["ok"] else []
                allowed = [a for a, name in enumerate(ARMS)
                           if (name != "remédio" or dims) and (name != "reparo" or (dims and i == fix))]
                arm = ARMS[be.bandit_pick(bandit, UCB_C, allowed)]
            before = len(hist)
            child = None
            if arm == "reparo":
                child, _ = repair(pop[i].copy(), R[i])
                if child is None:
                    arm = "de"
            if arm == "remédio":
                dims = remedy_dims(R[i])
                child = pop[i].copy()
                child[dims] = trial[i][dims]
            elif arm in boxes:
                child = boxes[arm][i]
            elif arm == "de":
                child = trial[i]
            uk, r = ev(child)
            if r is None:
                break
            cost = len(hist) - before
            if bandit is not None:
                be.bandit_update(bandit, ARMS.index(arm), _reward(R[i], r, cost), PH_DELTA, PH_GAMMA)
            if wins(r, R[i], eps):
                pop[i], R[i] = uk, r
            if stop_ok and st["done"]:
                break
    return st["x"], st["best"]
