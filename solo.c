/*
 * solo.c -- trem de pouso e ponto de cauda
 *
 * Cada contato e uma mola-amortecedor vertical, N = max(0, k d + c d'),
 * com atrito de rolamento na direcao da roda e atrito lateral, ambos
 * regularizados por tanh(v / 5 cm/s). A bequilha vira com o comando dw.
 * Freio nas principais durante o assentamento e depois do pouso.
 */
#include <math.h>
#include "modelo.h"

void solo_calcula(const Sim *s, const double *x, double R[3][3], const double *rcg, double dw,
                  double *F, double *M, double *N)
{
    const Param *a = &s->a;
    double VB[3] = { x[XU], x[XV], x[XW] }, w[3] = { x[XP], x[XQ], x[XR] };
    for (int i = 0; i < 3; i++) F[i] = M[i] = 0.0;
    for (int i = 0; i < a->nct; i++) {
        const Contato *ct = &a->ct[i];
        N[i] = 0.0;
        double pc[3]; mulR(R, ct->r, pc);
        double pen = x[XD] + pc[2];                    /* > 0: comprimido */
        if (pen <= 0.0) continue;
        double wr[3], vb[3], vn[3];
        cross(w, ct->r, wr);
        for (int j = 0; j < 3; j++) vb[j] = VB[j] + wr[j];
        mulR(R, vb, vn);
        double Nn = ct->k * pen + ct->c * vn[2];
        if (Nn < 0.0) Nn = 0.0;
        double dir = ct->tipo == 0 ? dw : 0.0;
        double fb[3] = { cos(dir), sin(dir), 0.0 }, fn[3];
        mulR(R, fb, fn);
        double fh = hypot(fn[0], fn[1]), fx = fn[0] / fh, fy = fn[1] / fh, lx = -fy, ly = fx;
        double vl = vn[0] * fx + vn[1] * fy, vt = vn[0] * lx + vn[1] * ly;
        double mu = a->mu_r, mul = a->mu_lat;
        if (ct->tipo == 1 && s->freios) mu = a->mu_freio;
        if (ct->tipo == 1 && s->pousou) mu = a->mu_pouso;
        if (ct->tipo == 2) mu = mul = a->mu_cauda;
        double Fl = -mu * Nn * tanh(vl / 0.05), Ft = -mul * Nn * tanh(vt / 0.05);
        double FN[3] = { Fl * fx + Ft * lx, Fl * fy + Ft * ly, -Nn }, FB[3], MB[3];
        mulRT(R, FN, FB);
        double rc[3] = { ct->r[0] - rcg[0], ct->r[1] - rcg[1], ct->r[2] - rcg[2] };
        cross(rc, FB, MB);
        for (int j = 0; j < 3; j++) { F[j] += FB[j]; M[j] += MB[j]; }
        N[i] = Nn;
    }
}
