/*
 * desempenho.c -- pontos de desempenho (voo equilibrado) por velocidade
 *
 * Para cada V resolve, por Newton com jacobiano numerico, o equilibrio
 * longitudinal nos eixos do vento (forcas de aero + helice, momento no CG):
 *   X_w - m g sin(gama) = 0,   Z_w + n m g cos(gama) = 0,   M = 0
 * com tres incognitas escolhidas por caso:
 *   voo nivelado:       alfa, de, acelerador        (gama = 0, n = 1)
 *   subida maxima:      alfa, de, gama              (acelerador = 1)
 *   planeio motor lento: alfa, de, gama             (acelerador = 0)
 *   curva nivelada:     alfa, de, acelerador        (n = 1/cos(phi))
 * O fator de carga maximo em curva e limitado pelo estol da asa
 * (C_L/C_Lmax da meia asa = kCL) e, em curva sustentada, pelo motor
 * (acelerador = 1). Raio: R = V^2 / (g sqrt(n^2 - 1)).
 */
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include "modelo.h"

typedef struct { const Param *a; double m, rcg[3], V; int caso; double fixo_thr, fixo_gam, fixo_n; } Ctx;
typedef struct { double razao, T, D, P, CL; } Extra;

static double rps_equilibrio(const Param *a, const double *Vr, const double *rcg, double thr)
{
    double w[3] = { 0, 0, 0 }, lo = 1.0, hi = 600.0;
    Prop p;
    prop_calcula(a, Vr, w, rcg, lo, thr, &p);
    if (p.drps <= 0.0) return lo;
    for (int it = 0; it < 60; it++) {
        double mid = 0.5 * (lo + hi);
        prop_calcula(a, Vr, w, rcg, mid, thr, &p);
        if (p.drps > 0.0) lo = mid; else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/* u = (alfa, de, z), z = acelerador (caso 0, 3) ou gama (caso 1, 2) */
static void residuo(const Ctx *c, const double *u, double *r, Extra *e)
{
    const Param *a = c->a;
    double al = u[0], de = u[1];
    double thr = c->fixo_thr, gam = c->fixo_gam, n = c->fixo_n;
    if (c->caso == 0 || c->caso == 3) thr = u[2]; else gam = u[2];
    double V = c->V, Vr[3] = { V * cos(al), 0.0, V * sin(al) }, w[3] = { 0, 0, 0 };
    Aero ae; Prop pr;
    aero_calcula(a, Vr, w, c->rcg, 100.0, de, 0.0, 0.0, &ae);
    double rps = rps_equilibrio(a, Vr, c->rcg, thr);
    prop_calcula(a, Vr, w, c->rcg, rps, thr, &pr);
    double ca = cos(al), sa = sin(al), W = c->m * G0;
    double Fx = ae.F[0] + pr.F[0], Fz = ae.F[2] + pr.F[2];
    r[0] = (Fx * ca + Fz * sa - W * sin(gam)) / W;
    r[1] = (-Fx * sa + Fz * ca + n * W * cos(gam)) / W;
    r[2] = (ae.M[1] + pr.M[1]) / (W * a->cref);
    if (e) {
        e->razao = ae.razaoCL; e->T = pr.T; e->P = pr.P;
        e->D = -(ae.F[0] * ca + ae.F[2] * sa);
        e->CL = (-ae.F[2] * ca + ae.F[0] * sa) / (0.5 * a->rho * V * V * a->Sref);
    }
}

static int newton(const Ctx *c, double *u, Extra *e)
{
    const double lo[3] = { -0.2, -0.35, c->caso == 0 || c->caso == 3 ? 0.02 : -0.7 };
    const double hi[3] = { 0.45, 0.35, c->caso == 0 || c->caso == 3 ? 3.0 : 0.7 };
    for (int it = 0; it < 120; it++) {
        double r[3], J[3][3], du[3];
        residuo(c, u, r, NULL);
        double nr = fabs(r[0]) + fabs(r[1]) + fabs(r[2]);
        if (nr < 1e-9) break;
        for (int j = 0; j < 3; j++) {
            double up[3] = { u[0], u[1], u[2] }, rp[3], h = 1e-6;
            up[j] += h;
            residuo(c, up, rp, NULL);
            for (int i = 0; i < 3; i++) J[i][j] = (rp[i] - r[i]) / h;
        }
        double b[3] = { -r[0], -r[1], -r[2] };
        resolve3(J, b, du);
        const double passo[3] = { 0.08, 0.08, 0.25 };
        for (int i = 0; i < 3; i++) {
            if (!isfinite(du[i])) du[i] = (i == 2) ? 0.1 : 0.0;   /* jacobiano singular (motor sem corrente) */
            du[i] = sat(du[i], passo[i]);
        }
        double f = 1.0;
        for (int k = 0; k < 12; k++) {             /* passo amortecido */
            double ut[3], rt[3];
            for (int i = 0; i < 3; i++) ut[i] = lim(u[i] + f * du[i], lo[i], hi[i]);
            residuo(c, ut, rt, NULL);
            if (fabs(rt[0]) + fabs(rt[1]) + fabs(rt[2]) < nr || k == 11) { memcpy(u, ut, sizeof ut); break; }
            f *= 0.5;
        }
    }
    double r[3];
    residuo(c, u, r, e);
    return fabs(r[0]) + fabs(r[1]) + fabs(r[2]) < 1e-5;
}

int desempenho(const Sim *s, const char *pref)
{
    const Param *a = &s->a;
    double x[NX] = { 0 }, I[3][3], r1[3], rL[3];
    Ctx c; memset(&c, 0, sizeof c);
    c.a = a;
    carga_massa(s, x, &c.m, c.rcg, I, r1, rL);
    char nome[512];
    snprintf(nome, sizeof nome, "%s_desempenho.dat", pref);
    FILE *f = fopen(nome, "w");
    if (!f) { perror(nome); return 1; }
    fprintf(f, "V ok_n al_n de_n thr_n razao_n CL_n D_n T_n P_n ok_c gam_max roc_max thr_c "
               "ok_g gam_idle roc_idle n_estol R_estol phi_estol n_sust R_sust phi_sust\n");
    double un[3] = { 0.1, -0.05, 0.5 }, uc[3] = { 0.1, -0.05, 0.1 }, ug[3] = { 0.1, -0.05, -0.1 };
    double kCL = a->kCL > 0 ? a->kCL : 0.95;
    for (double V = 24.0; V >= 8.0 - 1e-9; V -= 0.25) {   /* de cima para baixo: chute vem do anterior */
        Extra en, ec, eg;
        c.V = V;
        c.caso = 0; c.fixo_gam = 0.0; c.fixo_n = 1.0;
        int okn = newton(&c, un, &en);
        c.caso = 1; c.fixo_thr = 1.0; c.fixo_n = 1.0;
        int okc = newton(&c, uc, &ec);
        c.caso = 2; c.fixo_thr = 0.0; c.fixo_n = 1.0;
        int okg = newton(&c, ug, &eg);
        /* curvas: bisseccao no fator de carga */
        double nest = 1.0, nsus = 1.0;
        for (int tipo = 0; tipo < 2; tipo++) {
            double lo = 1.0, hi = 6.0, u[3] = { un[0], un[1], un[2] };
            for (int it = 0; it < 40; it++) {
                double nm = 0.5 * (lo + hi), ut[3] = { u[0], u[1], u[2] };
                Extra et;
                c.caso = 3; c.fixo_gam = 0.0; c.fixo_n = nm;
                int ok = newton(&c, ut, &et);
                int dentro = ok && et.razao <= kCL && (tipo == 0 || ut[2] <= 1.0);
                if (dentro) { lo = nm; memcpy(u, ut, sizeof u); } else hi = nm;
            }
            if (tipo == 0) nest = lo; else nsus = lo;
        }
        double Rest = nest > 1.0001 ? V * V / (G0 * sqrt(nest * nest - 1.0)) : 1e9;
        double Rsus = nsus > 1.0001 ? V * V / (G0 * sqrt(nsus * nsus - 1.0)) : 1e9;
        fprintf(f, "%.2f %d %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.3f %d %.5f %.5f %.3f %d %.5f %.5f "
                   "%.5f %.4g %.4f %.5f %.4g %.4f\n",
                V, okn && en.razao <= 1.0, un[0] / DEG, un[1] / DEG, un[2], en.razao, en.CL, en.D, en.T, en.P,
                okc && ec.razao <= 1.0, uc[2] / DEG, V * sin(uc[2]), 1.0,
                okg, ug[2] / DEG, V * sin(ug[2]),
                nest, Rest, acos(1.0 / nest) / DEG, nsus, Rsus, acos(1.0 / nsus) / DEG);
    }
    fclose(f);
    printf("massa=%.4f\nxcg=%.5f\n", c.m, c.rcg[0]);
    return 0;
}
