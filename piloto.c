/*
 * piloto.c -- piloto automatico
 *
 * Decolagem (Riboldi et al., 2022): acelerador cheio, profundor de0 ate a
 *   velocidade VR e depois de1 (com a taxa do servo); no chao, leme e
 *   bequilha seguem o eixo da pista e o aileron nivela as asas.
 * Depois de h_t: altura -> fator de carga vertical -> alfa pedido (com
 *   limite de alfa) -> profundor; velocidade pelo
 *   acelerador, que tambem recebe o erro de altura (energia total);
 *   lateral pelo curso (inclinacao) e leme zerando beta.
 * Pouso: abaixo de hflare, razao de descida proporcional a altura das rodas
 *   (arredondamento exponencial), motor cortado; no chao, freio.
 */
#include <math.h>
#include "modelo.h"

static double profundor_decolagem(const Sim *s, double t)
{
    const Param *a = &s->a;
    if (s->tR < 0.0 || t < s->tR) return a->de0;
    double d = a->de1 - a->de0, dmax = a->taxa_de * (t - s->tR);
    if (fabs(d) > dmax) d = sgn(d) * dmax;
    return a->de0 + d;
}

void piloto_comandos(const Sim *s, double t, const double *x, double Va, double Vg, double al,
                     double be, double chi, double hdot, double qb, double m, int nochao,
                     const Guia *g, Cmd *c, double *dx)
{
    const Param *a = &s->a;
    double h = -x[XD], Vgl = Vg > 3.0 ? Vg : 3.0;
    int noar = !nochao && !s->freios && !s->pousou;

    /* altura de referencia: segue o segmento com taxa limitada */
    double taxa = lim(a->Khr * (g->hseg - x[XHR]), -a->g_desce * Vgl, a->g_sobe * Vgl);
    /* prioridade da velocidade: abaixo de Vseg a subida pedida diminui (motor ja no maximo) */
    if (taxa > 0.0) taxa *= lim(1.0 - a->Kvs * (g->Vseg - Va), 0.0, 1.0);
    dx[XHR] = s->autop ? taxa : 0.0;
    c->href = s->autop ? x[XHR] : g->hseg;
    c->hdref = s->autop ? taxa : 0.0;
    double eh = c->href - h, ehd = c->hdref - hdot;

    /* ---------------- longitudinal ---------------- */
    double sph = sin(x[XPHI]), cph = cos(lim(x[XPHI], -75.0 * DEG, 75.0 * DEG));
    double qref = G0 / (Va > 3.0 ? Va : 3.0) * sph * sph / cph;   /* q de uma curva nivelada */
    c->alc = al;
    if (!s->autop) {
        c->thr = s->freios ? 0.0 : lim(a->taxa_acel * t, 0.0, 1.0);
        c->de = profundor_decolagem(s, t);
        c->thc = x[XTHE];
    } else if (s->pousou) {
        /* no chao: abaixa o nariz e corta o motor */
        c->thc = 0.0; c->thr = 0.0;
        c->de = a->Kthe * x[XTHE] + a->Kqe * x[XQ];
    } else {
        /* altura -> fator de carga vertical n*cos(phi) -> alfa pedido -> profundor
         *   h'' = g (n cos(phi) - cos(gama))  =>  n cos(phi) = cos(gama_ref) + Kn_h e_h + Kn_hd e_hdot + Kn_ih int(e_h)
         * a curva entra sozinha pelo 1/cos(phi), sem trocar de modo */
        double gref = atan2(c->hdref, Vgl);
        double nv = cos(gref) + a->Kn_h * eh + a->Kn_hd * ehd + a->Kn_ih * x[XIH];
        c->thr = lim(a->Dtrim + a->KV * (g->Vseg - Va) + a->KIV * x[XIV] + a->KHT * eh, 0.0, 1.0);
        if (s->flare) {             /* arredondamento exponencial: dh/dt = -h_rodas / tau */
            double hw = h - s->h_solo;
            /* nunca pede descer mais rapido do que ja desce: o arredondamento so freia a descida */
            c->hdref = -lim(hw / a->tau_flare, 0.2, (-hdot > 0.2 ? -hdot : 0.2));
            nv = 1.0 + a->Kfn * (c->hdref - hdot);
            if (hw < 0.3) c->thr = 0.0;   /* motor segura a velocidade ate quase tocar */
        }
        nv = lim(nv, 0.0, 3.0);
        double CLc = qb > 5.0 ? nv / cph * m * G0 / (qb * a->Sref) : a->ap_CL0;
        c->alc = lim((CLc - a->ap_CL0) / a->ap_CLa, -6.0 * DEG, a->alfa_max);   /* protecao de alfa */
        c->alim = (CLc - a->ap_CL0) / a->ap_CLa >= a->alfa_max;
        c->thc = x[XTHE] + (c->alc - al);   /* atitude equivalente (so para registro) */
        c->de = a->Kae * (al - c->alc) + a->Kqe * (x[XQ] - qref) + a->KIa * x[XITH];
    }
    c->de = sat(c->de, 20.0 * DEG);

    /* ---------------- latero-direcional ---------------- */
    if (nochao) {
        double psiref = g->chip - atan(a->Ky * g->ect + a->Ki * x[XIE]);
        double uy = a->Kpsi * wrap(psiref - x[XPSI]) - a->Kr * x[XR];   /* + : nariz p/ direita */
        c->da = -a->Kphia * x[XPHI] - a->Kpa * x[XP];
        c->dr = -uy;
        c->dw = a->Kbeq * uy;
        c->phic = 0.0;
        dx[XPHC] = -x[XPHC] / a->tau_phi;
    } else {
        /* inclinacao pedida passa por um filtro com taxa maxima (sem degrau na troca de etapa) */
        /* inclinacao maxima que a asa sustenta sem perder altura: n = 1/cos(phi) <= n_max(alfa_max) */
        double CLlim = a->ap_CL0 + a->ap_CLa * a->alfa_max;
        double nmax = qb * a->Sref * CLlim / (m * G0);
        double philim = nmax > 1.0 ? acos(1.0 / nmax) : 0.0;
        if (philim > a->phimax) philim = a->phimax;
        double phir = (Vg > 3.0) ? sat(g->phiff + a->Kchi * wrap(g->chid - chi), philim) : 0.0;
        dx[XPHC] = sat((phir - x[XPHC]) / a->tau_phi, a->pmax_cmd);
        c->phic = x[XPHC];
        c->da = a->Kphia * (c->phic - x[XPHI]) - a->Kpa * x[XP];
        c->dr = -a->Kbeta * be;
        c->dw = 0.0;
    }
    c->da = sat(c->da, 20.0 * DEG); c->dr = sat(c->dr, 25.0 * DEG); c->dw = sat(c->dw, 20.0 * DEG);

    /* ---------------- integradores ---------------- */
    int ativo = s->autop && noar && !s->flare;
    dx[XIH] = ativo ? sat(eh, 3.0) : 0.0;
    double thr_livre = a->Dtrim + a->KV * (g->Vseg - Va) + a->KIV * x[XIV] + a->KHT * eh;
    int satura = (thr_livre > 1.0 && g->Vseg > Va) || (thr_livre < 0.0 && g->Vseg < Va);
    dx[XIV] = (ativo && !satura) ? (g->Vseg - Va) : 0.0;
    dx[XITH] = ativo ? sat(al - c->alc, 5.0 * DEG) : 0.0;
    dx[XIE] = nochao ? g->ect : 0.0;
}
