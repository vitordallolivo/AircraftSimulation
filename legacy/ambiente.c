/* ambiente.c -- vento 3D numa direcao (perfil 1/7 com a altura) e rajada 1-cos */
#include <math.h>
#include "modelo.h"

/* W em NED; psiw = direcao DE ONDE o vento vem, chiw = elevacao (+ sobe) */
void ambiente_vento(const Sim *s, double t, double h, double *W)
{
    const Param *a = &s->a;
    double hh = h > 0.1 ? h : 0.1;
    double V = a->Vw10 * pow(hh / a->hw_ref, 1.0 / 7.0);
    W[0] = -V * cos(a->chiw) * cos(a->psiw);
    W[1] = -V * cos(a->chiw) * sin(a->psiw);
    W[2] = -V * sin(a->chiw);
    if (a->rajada && s->tg >= 0.0 && t >= s->tg && t <= s->tg + a->Tg) {
        double f = 0.5 * (1.0 - cos(2.0 * PI * (t - s->tg) / a->Tg));
        for (int i = 0; i < 3; i++) W[i] += f * a->Ug[i];
    }
}
