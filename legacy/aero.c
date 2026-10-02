/*
 * aero.c -- aerodinamica por componentes
 *
 * Cada superficie (meia asa, EH, EV) e um painel com centro aerodinamico,
 * corda e normal proprios. A velocidade local e V_ar + w x r, entao os
 * amortecimentos (C_mq, C_lp, C_nr...) e os efeitos de diedro e de cauda
 * (C_lb, C_nb) aparecem sozinhos, sem derivadas de estabilidade prontas.
 *   alfa_local = atan2(v . ez, v . ex) - downwash + sinal * tau * delta
 *   L = q S CL(alfa), perpendicular a v; D = q S (CD0 + CL^2/(pi e AR) phi(h))
 * A fuselagem entra com uma area de arrasto e C_ma, C_nb, C_Yb proprios.
 */
#include <math.h>
#include <string.h>
#include "modelo.h"

static double cl_painel(const Superficie *s, double al, double M)
{
    double sg = sigma_estol(al, s->a0, M), sa = sin(al), ca = cos(al);
    return (1.0 - sg) * (s->CL0 + s->CLa * al) + sg * 2.0 * sgn(al) * sa * sa * ca;
}

/* eixos do painel e angulo de estol que da o CLmax pedido */
void aero_inicia(Param *a)
{
    for (int k = 0; k < a->nsup; k++) {
        Superficie *s = &a->sup[k];
        double i = s->incid;
        double ex[3] = { cos(i), 0.0, -sin(i) }, ez[3] = { sin(i), 0.0, cos(i) };
        if (s->vertical) {                 /* normal para +y; incid = calagem em guinada */
            ex[0] = cos(i); ex[1] = -sin(i); ex[2] = 0.0;
            ez[0] = sin(i); ez[1] = cos(i);  ez[2] = 0.0;
        } else {                           /* diedro: gira em x, a normal inclina para dentro */
            double ang = -s->lado * s->diedro, c = cos(ang), sn = sin(ang);
            double y, z;
            y = ez[1]; z = ez[2]; ez[1] = y * c - z * sn; ez[2] = y * sn + z * c;
            y = ex[1]; z = ex[2]; ex[1] = y * c - z * sn; ex[2] = y * sn + z * c;
        }
        memcpy(s->ex, ex, sizeof ex); memcpy(s->ez, ez, sizeof ez);
        cross(s->ez, s->ex, s->ey);
        double lo = 0.02, hi = 0.8;
        for (int it = 0; it < 60; it++) {
            s->a0 = 0.5 * (lo + hi);
            double pk = -1e9;
            for (double al = 0.0; al < 0.9; al += 2e-4) { double c = cl_painel(s, al, a->Mst); if (c > pk) pk = c; }
            if (pk > s->CLmax) hi = s->a0; else lo = s->a0;
        }
    }
}

/*
 * Vr: velocidade do ponto O em relacao ao ar (corpo); w: (p,q,r);
 * rcg: CG atual (momentos sao dados no CG); h: altura do ponto O.
 */
void aero_calcula(const Param *a, const double *Vr, const double *w, const double *rcg, double h,
                  double de, double da, double dr, Aero *o)
{
    memset(o, 0, sizeof *o);
    double Va = sqrt(dot(Vr, Vr));
    double alfa = atan2(Vr[2], Vr[0]);
    for (int k = 0; k < a->nsup; k++) {
        const Superficie *s = &a->sup[k];
        double wr[3], v[3];
        cross(w, s->r, wr);
        for (int i = 0; i < 3; i++) v[i] = Vr[i] + wr[i];
        double u = dot(v, s->ex), ww = dot(v, s->ez), V2 = u * u + ww * ww;
        if (V2 < 1e-6) continue;
        double Vp = sqrt(V2);
        double al = atan2(ww, u);
        if (s->downwash) al -= s->eps0 + s->depsda * alfa;
        double del = s->ctrl == 1 ? da : s->ctrl == 2 ? de : s->ctrl == 3 ? dr : 0.0;
        al += s->sinal * s->tau * del;
        double CL = cl_painel(s, al, a->Mst);
        double sg = sigma_estol(al, s->a0, a->Mst);
        double fge = 1.0;
        if (!s->vertical) {                 /* efeito solo (McCormick) */
            double hp = h - s->r[2], r16 = 16.0 * (hp > 0.01 ? hp : 0.01) / a->bref;
            fge = r16 * r16 / (1.0 + r16 * r16);
        }
        double CDi = (1.0 - sg) * CL * CL / (PI * s->e * s->AR) * fge;
        double CD = s->CD0 + CDi + sg * 1.2 * sin(al) * sin(al);
        double qS = 0.5 * a->rho * V2 * s->eta * s->S;
        double F[3], Fi[3], M[3], rc[3];
        for (int i = 0; i < 3; i++) {
            double l = (ww * s->ex[i] - u * s->ez[i]) / Vp;       /* sustentacao: perpendicular a v */
            double d = -(u * s->ex[i] + ww * s->ez[i]) / Vp;      /* arrasto: contra v               */
            F[i] = qS * (CL * l + CD * d);
            Fi[i] = qS * CDi * d;
            rc[i] = s->r[i] - rcg[i];
        }
        cross(rc, F, M);
        for (int i = 0; i < 3; i++) M[i] += qS * s->c * s->Cmac * s->ey[i];
        for (int i = 0; i < 3; i++) {
            o->Fg[s->grupo][i] += F[i]; o->Mg[s->grupo][i] += M[i];
            o->F[i] += F[i]; o->M[i] += M[i]; o->Fi[i] += Fi[i];
        }
        if (s->grupo == 0 && s->CLmax > 0) {
            double r = CL / s->CLmax;
            if (r > o->razaoCL) o->razaoCL = r;
        }
    }
    /* fuselagem */
    if (Va > 0.1) {
        double qS = 0.5 * a->rho * Va * Va * a->Sref, be = asin(Vr[1] / Va);
        double F[3], M[3], rc[3];
        for (int i = 0; i < 3; i++) F[i] = -0.5 * a->rho * Va * a->fus_CDS * Vr[i];
        F[1] += qS * a->fus_CYb * be;
        for (int i = 0; i < 3; i++) rc[i] = a->fus_r[i] - rcg[i];
        cross(rc, F, M);
        M[1] += qS * a->cref * a->fus_Cma * alfa;
        M[2] += qS * a->bref * a->fus_Cnb * be;
        for (int i = 0; i < 3; i++) { o->Fg[3][i] += F[i]; o->Mg[3][i] += M[i]; o->F[i] += F[i]; o->M[i] += M[i]; }
    }
}
