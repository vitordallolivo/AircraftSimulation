/*
 * carga.c -- massa, CG e inercia variaveis; sloshing; extracao LAPES
 *
 * Sloshing: pendulo equivalente do 1o modo de um tanque cilindrico
 * (Abramson, NASA SP-106), xi = 1,841:
 *   w1^2 = (g xi / R) tanh(xi h / R),  l1 = g / w1^2,
 *   m1 = m_liq 2 tanh(xi h/R) / (xi (xi^2 - 1) h/R),  m0 = m_liq - m1.
 *   l1 eta'' = a_ap,x cos(eta) - a_ap,z sin(eta) - 2 zeta w1 l1 eta'
 * a_ap e a gravidade aparente no corpo (menos a forca especifica).
 * LAPES: o paraquedas puxa a carga com Fext; ela desliza na baia com
 * atrito mu_b; o aviao sente so o atrito e o CG que anda para tras.
 */
#include <math.h>
#include <string.h>
#include "modelo.h"

void carga_inicia(Param *a)
{
    double xi = 1.841, th = tanh(xi * a->htq / a->Rtq);
    a->mliq = a->rho_liq * PI * a->Rtq * a->Rtq * a->htq;
    a->w1 = sqrt(G0 * xi / a->Rtq * th);
    a->l1 = G0 / (a->w1 * a->w1);
    a->m1 = a->mliq * 2.0 * th / (xi * (xi * xi - 1.0) * a->htq / a->Rtq);
    a->m0 = a->mliq - a->m1;
}

void carga_massa(const Sim *s, const double *x, double *m, double *rcg, double I[3][3],
                 double *r1, double *rL)
{
    const Param *a = &s->a;
    double ex = a->slosh ? x[XEX] : 0.0, ey = a->slosh ? x[XEY] : 0.0;
    r1[0] = a->rt[0] + a->l1 * sin(ex);
    r1[1] = a->rt[1] + a->l1 * sin(ey);
    r1[2] = a->rt[2] - a->l1 + a->l1 * cos(ex) * cos(ey);
    rL[0] = a->rL[0] - x[XSL]; rL[1] = a->rL[1]; rL[2] = a->rL[2];
    double mk[4] = { a->m_seca, a->m0, a->m1, s->solto ? 0.0 : a->mL };
    const double *rk[4] = { a->r_seca, a->rt, r1, rL };
    /* inercia da aeronave seca dada no CG dela; as massas pontuais somam por Steiner */
    double I0[3][3] = { { a->Ixx, 0, -a->Ixz }, { 0, a->Iyy, 0 }, { -a->Ixz, 0, a->Izz } };
    *m = 0.0;
    rcg[0] = rcg[1] = rcg[2] = 0.0;
    for (int k = 0; k < 4; k++) {
        *m += mk[k];
        double r2 = dot(rk[k], rk[k]);
        for (int i = 0; i < 3; i++) {
            rcg[i] += mk[k] * rk[k][i];
            for (int j = 0; j < 3; j++) I0[i][j] += mk[k] * ((i == j ? r2 : 0.0) - rk[k][i] * rk[k][j]);
        }
    }
    for (int i = 0; i < 3; i++) rcg[i] /= *m;
    double c2 = dot(rcg, rcg);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) I[i][j] = I0[i][j] - *m * ((i == j ? c2 : 0.0) - rcg[i] * rcg[j]);
}

void carga_slosh(const Param *a, const double *x, const double *aap, const double *r1,
                 const double *rcg, double *dx, double *F, double *M)
{
    F[0] = F[1] = F[2] = M[0] = M[1] = M[2] = 0.0;
    if (!a->slosh) return;
    double ex = x[XEX], ey = x[XEY];
    double exdd = (aap[0] * cos(ex) - aap[2] * sin(ex)) / a->l1 - 2.0 * a->zeta_s * a->w1 * x[XEXD];
    double eydd = (aap[1] * cos(ey) - aap[2] * sin(ey)) / a->l1 - 2.0 * a->zeta_s * a->w1 * x[XEYD];
    dx[XEX] = x[XEXD]; dx[XEY] = x[XEYD]; dx[XEXD] = exdd; dx[XEYD] = eydd;
    double arel[3] = { a->l1 * (exdd * cos(ex) - x[XEXD] * x[XEXD] * sin(ex)),
                       a->l1 * (eydd * cos(ey) - x[XEYD] * x[XEYD] * sin(ey)), 0.0 };
    double rc[3];
    for (int i = 0; i < 3; i++) { F[i] = -a->m1 * arel[i]; rc[i] = r1[i] - rcg[i]; }
    cross(rc, F, M);
}

void carga_lapes(const Sim *s, const double *x, const double *aap, const double *rL,
                 const double *rcg, double *dx, double *F, double *M)
{
    const Param *a = &s->a;
    F[0] = F[1] = F[2] = M[0] = M[1] = M[2] = 0.0;
    if (!s->extraindo || s->solto) return;
    double nz = aap[2] > 0.0 ? aap[2] : 0.0;
    double fr = a->mu_b * a->mL * nz;
    dx[XSL] = x[XSLD];
    dx[XSLD] = a->Fext_g * G0 - fr / a->mL;
    F[0] = -fr;
    double rc[3] = { rL[0] - rcg[0], rL[1] - rcg[1], rL[2] - rcg[2] };
    cross(rc, F, M);
}
