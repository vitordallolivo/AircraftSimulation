/*
 * trajeto.c -- segmentos do percurso e guiamento lateral
 *
 * Reta: campo vetorial  chi_d = chi_p - chi_inf (2/pi) atan(k e)
 * Arco: orbita           chi_d = fi + lam (pi/2 + atan(k_o (d - R) / R))
 * (Beard e McLain, cap. 10). A altura e a velocidade de cada segmento
 * vao de (h0, V0) a (h1, V1) por uma curva cosseno; no segmento de pouso
 * a altura cai em rampa ate o ponto de toque.
 */
#include <math.h>
#include "modelo.h"

static double suave(double x) { x = lim(x, 0.0, 1.0); return 0.5 * (1.0 - cos(PI * x)); }

void trajeto_guia(const Sim *s, double n, double e, double Vg, Guia *g)
{
    const Param *a = &s->a;
    const Segmento *sg = &a->sg[s->seg];
    if (!sg->arco) {
        double cn = cos(sg->chi0), sn = sin(sg->chi0);
        g->s = (n - sg->n0) * cn + (e - sg->e0) * sn;
        g->ect = -(n - sg->n0) * sn + (e - sg->e0) * cn;        /* + : a direita */
        g->chip = sg->chi0;
        g->chid = sg->chi0 - a->chi_inf * (2.0 / PI) * atan(a->kvf * g->ect);
        g->phiff = 0.0;
        /* antecipacao: se a proxima perna e curva, comeca a inclinar t_lead segundos antes */
        if (s->seg + 1 < a->nseg && a->sg[s->seg + 1].arco && a->tlead > 0.0) {
            const Segmento *nx = &a->sg[s->seg + 1];
            double w = 1.0 - (sg->L - g->s) / (Vg * a->tlead + 1e-6);
            g->phiff = lim(w, 0.0, 1.0) * nx->lam * atan(Vg * Vg / (G0 * nx->R));
        }
    } else {
        double fi = atan2(e - sg->ce, n - sg->cn), fi0 = atan2(sg->e0 - sg->ce, sg->n0 - sg->cn);
        double d = hypot(n - sg->cn, e - sg->ce), dl = sg->lam * (fi - fi0);
        while (dl < -0.5 * PI) dl += 2.0 * PI;
        while (dl >= 1.5 * PI) dl -= 2.0 * PI;
        g->s = sg->R * dl;
        g->ect = sg->lam * (d - sg->R);                          /* + : por fora */
        g->chip = fi + sg->lam * 0.5 * PI;
        /* ganho da orbita em 1/m limitado: em raio pequeno k_o/R ficaria agressivo demais */
        g->chid = fi + sg->lam * (0.5 * PI + atan(a->korb * (d - sg->R) / fmax(sg->R, a->Lorb)));
        g->phiff = sg->lam * atan(Vg * Vg / (G0 * sg->R));
        if (a->tlead > 0.0 && s->seg + 1 < a->nseg && !a->sg[s->seg + 1].arco)
            g->phiff *= lim((sg->L - g->s) / (Vg * a->tlead + 1e-6), 0.0, 1.0);
    }
    double x = g->s / sg->L;
    g->hseg = sg->h0 + (sg->h1 - sg->h0) * suave(x);
    g->Vseg = sg->V0 + (sg->V1 - sg->V0) * suave(x);
    if (sg->pouso) g->hseg = sg->h0 + (s->h_solo + 0.1 - sg->h0) * lim(g->s / (sg->L - sg->folga), 0.0, 1.0);
}
