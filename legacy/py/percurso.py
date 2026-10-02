"""Percurso da missao como uma corrente de pernas (retas e curvas).

Cada perna comeca onde a anterior terminou, entao mudar o raio de uma curva
so altera as pernas seguintes; o que veio antes (e um checkpoint salvo
antes dela) continua valido. A altura e a velocidade de cada perna vao do
valor da perna anterior ao valor pedido nela (curva cosseno no C).

    pernas = [reta(100, h=15, nome="subida", decolagem=1), curva(80, h=15), ...]
    perc = monta(pernas, eventos=[evento("lapes", 4, 170.0)])
"""
import copy
import math


def reta(L, h=None, V=None, nome="reta", **flags):
    return dict(tipo="reta", L=float(L), h=h, V=V, nome=nome, **flags)


def curva(R, ang=180.0, lado=1, h=None, V=None, nome="curva", **flags):
    """lado = +1 curva para a direita, -1 para a esquerda; ang em graus"""
    return dict(tipo="curva", R=float(R), ang=float(ang), lado=lado, h=h, V=V, nome=nome, **flags)


def evento(tipo, perna, s):
    """tipo 'lapes' ou 'rajada'; s = distancia (m) dentro da perna"""
    return dict(tipo=tipo, seg=int(perna), s=float(s))


def monta(pernas, eventos=(), n0=0.0, e0=0.0, chi0=0.0, h0=0.0, V0=14.0):
    segs = []
    n, e, chi, h, V = n0, e0, math.radians(chi0), h0, V0
    for p in pernas:
        h1 = h if p.get("h") is None else p["h"]
        V1 = V if p.get("V") is None else p["V"]
        sg = dict(nome=p["nome"].replace(" ", "_"), h0=h, h1=h1, V0=V, V1=V1)
        for k in ("decolagem", "pouso", "folga"):
            if k in p:
                sg[k] = p[k]
        if p["tipo"] == "reta":
            sg.update(arco=0, n0=n, e0=e, chi0=math.degrees(chi), L=p["L"])
            n += p["L"] * math.cos(chi); e += p["L"] * math.sin(chi)
        else:
            lam, R, a = p["lado"], p["R"], math.radians(p["ang"])
            cn, ce = n + R * math.cos(chi + lam * math.pi / 2), e + R * math.sin(chi + lam * math.pi / 2)
            sg.update(arco=1, n0=n, e0=e, cn=cn, ce=ce, R=R, lam=lam, L=R * a)
            fi = math.atan2(e - ce, n - cn) + lam * a
            n, e = cn + R * math.cos(fi), ce + R * math.sin(fi)
            chi += lam * a
        segs.append(sg)
        h, V = h1, V1
    if pernas and pernas[0].get("decolagem"):
        segs[0]["h0"] = segs[0]["h1"]
    return dict(pernas=copy.deepcopy(pernas), segmentos=segs, eventos=list(eventos),
                nomes=[p["nome"] for p in pernas])


def altera(perc, i, **mudancas):
    """copia do percurso com a perna i alterada (ex.: R=40, V=13); as seguintes se deslocam"""
    pernas = copy.deepcopy(perc["pernas"])
    pernas[i].update(mudancas)
    s0 = perc["segmentos"][0]
    return monta(pernas, perc["eventos"], n0=s0["n0"], e0=s0["e0"], chi0=s0.get("chi0", 0.0),
                 h0=s0["h0"], V0=s0["V0"])


def com_eventos(perc, eventos):
    p = copy.deepcopy(perc)
    p["eventos"] = list(eventos)
    return p


def circuito(raios=250.0 / math.pi, reta_=270.0, frente=100.0, hc=15.0, hL=3.0, Vc=15.0, VL=13.5, Vap=13.0,
             s_lapes=None, s_rajada=135.0, folga_pouso=50.0):
    """Circuito da figura: 4 m + 96 m, curva, 270 m, curva (desce), passagem LAPES, curva (sobe),
    270 m, curva, descida de 170 m e pouso. `raios` pode ser um numero ou uma lista de 4 raios."""
    R = list(raios) if isinstance(raios, (list, tuple)) else [raios] * 4
    tras = reta_ - frente
    pernas = [
        reta(frente, h=hc, V=Vc, nome="decolagem + subida", decolagem=1),
        curva(R[0], h=hc, V=Vc, nome="manobra 1"),
        reta(reta_, h=hc, V=Vc, nome="cruzeiro 1"),
        curva(R[1], h=hL, V=VL, nome="manobra 2 (desce)"),
        reta(reta_, h=hL, V=VL, nome="passagem LAPES"),
        curva(R[2], h=hc, V=Vc, nome="manobra 3 (sobe)"),
        reta(reta_, h=hc, V=Vc, nome="cruzeiro 2"),
        curva(R[3], h=hc, V=Vap, nome="manobra 4"),
        reta(tras, h=0.0, V=Vap, nome="descida e pouso", pouso=1, folga=folga_pouso),
    ]
    ev = [evento("rajada", 2, s_rajada), evento("lapes", 4, tras if s_lapes is None else s_lapes)]
    return monta(pernas, ev, h0=hc, V0=Vc)
