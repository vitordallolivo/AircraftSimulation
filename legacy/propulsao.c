/*
 * propulsao.c -- helice por tabela C_T(J), C_P(J) + motor BLDC + bateria
 *
 *   J = V_p / (n D),  V_p = (V_ar + w x r_p) . e_T
 *   T = C_T rho n^2 D^4,  Q = C_P / (2 pi) rho n^2 D^5
 *   I = (u V_oc - K_e w) / (R_m + u^2 R_int)      (u: acelerador)
 *   (J_m + I_p) 2 pi dn/dt = K_e I - B w - tau_c - Q
 * Forca T e_T no cubo; momento r x F - sentido Q e_T; giroscopico -w x H.
 */
#include <math.h>
#include <string.h>
#include "modelo.h"

static void helice_coef(const Param *a, double J, double *CT, double *CP)
{
    int i, n = a->nhel;
    if (n < 2) { *CT = 0.0; *CP = 0.002; return; }
    if (J <= a->hel_J[0]) { *CT = a->hel_CT[0]; *CP = a->hel_CP[0]; return; }
    for (i = 1; i < n - 1 && J > a->hel_J[i]; i++) { }
    double f = (J - a->hel_J[i - 1]) / (a->hel_J[i] - a->hel_J[i - 1]);
    *CT = a->hel_CT[i - 1] + f * (a->hel_CT[i] - a->hel_CT[i - 1]);
    *CP = a->hel_CP[i - 1] + f * (a->hel_CP[i] - a->hel_CP[i - 1]);
    if (*CP < 0.002) *CP = 0.002;
}

void prop_calcula(const Param *a, const double *Vr, const double *w, const double *rcg,
                  double rps, double thr, Prop *o)
{
    memset(o, 0, sizeof *o);
    double eT[3] = { cos(a->phiT) * cos(a->psiT), cos(a->phiT) * sin(a->psiT), -sin(a->phiT) };
    double n = rps > 1.0 ? rps : 1.0, wm = 2.0 * PI * n;
    double wr[3], v[3];
    cross(w, a->rp, wr);
    for (int i = 0; i < 3; i++) v[i] = Vr[i] + wr[i];
    o->J = dot(v, eT) / (n * a->D);
    double CT, CP;
    helice_coef(a, o->J, &CT, &CP);
    o->T = CT * a->rho * n * n * pow(a->D, 4);
    o->Q = CP / (2.0 * PI) * a->rho * n * n * pow(a->D, 5);
    double rc[3] = { a->rp[0] - rcg[0], a->rp[1] - rcg[1], a->rp[2] - rcg[2] }, H[3];
    for (int i = 0; i < 3; i++) o->F[i] = o->T * eT[i];
    cross(rc, o->F, o->M);
    for (int i = 0; i < 3; i++) {
        o->M[i] -= a->sentido * o->Q * eT[i];
        H[i] = a->sentido * (a->Ip + a->Jm) * wm * eT[i];
    }
    cross(w, H, o->Mgir);
    for (int i = 0; i < 3; i++) o->Mgir[i] = -o->Mgir[i];
    double Ke = 60.0 / (2.0 * PI * a->Kv);
    o->I = lim((thr * a->Voc - Ke * wm) / (a->Rm + thr * thr * a->Rint), 0.0, a->Imax);
    o->Ibat = thr * o->I;
    o->Vbus = a->Voc - a->Rint * o->Ibat;
    o->P = o->Vbus * o->Ibat;
    o->drps = (Ke * o->I - a->B * wm - a->tauc - o->Q) / (2.0 * PI * (a->Jm + a->Ip));
}
