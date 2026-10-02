/*
 * dinamica.c -- equacao mestre f(t, x) e integracao por RK4
 *
 * Newton e Euler no CG atual (que muda com a carga e o liquido):
 *   m (dV/dt + w x V) = F_aero + F_helice + F_solo + F_liquido + F_carga + m g
 *   I_cg dw/dt + w x (I_cg w) = soma dos momentos no CG (giroscopico incluido)
 * mais cinematica (Euler), navegacao, motor, sloshing, LAPES e piloto.
 */
#include <math.h>
#include <string.h>
#include "modelo.h"

void dinamica_f(const Sim *s, double t, const double *x, double *dx, Saida *o)
{
    const Param *a = &s->a;
    Saida oo;
    if (!o) o = &oo;
    memset(dx, 0, NX * sizeof(double));
    double R[3][3]; rotacao(x, R);
    double VB[3] = { x[XU], x[XV], x[XW] }, w[3] = { x[XP], x[XQ], x[XR] };
    double h = -x[XD];

    /* massa, CG e inercia */
    double m, rcg[3], I[3][3], r1[3], rL[3];
    carga_massa(s, x, &m, rcg, I, r1, rL);

    /* vento e velocidade em relacao ao ar */
    double WN[3], WB[3], Vr[3];
    ambiente_vento(s, t, h, WN);
    mulRT(R, WN, WB);
    for (int i = 0; i < 3; i++) Vr[i] = VB[i] - WB[i];
    double Va = sqrt(dot(Vr, Vr));
    double al = atan2(Vr[2], Vr[0]), be = Va > 0.1 ? asin(Vr[1] / Va) : 0.0;
    double qb = 0.5 * a->rho * Va * Va;
    double vn[3]; mulR(R, VB, vn);
    double Vg = hypot(vn[0], vn[1]), chi = atan2(vn[1], vn[0]);

    int nochao = 0;
    for (int i = 0; i < a->nct; i++) { double pc[3]; mulR(R, a->ct[i].r, pc); if (x[XD] + pc[2] > 0.0) nochao = 1; }

    /* guiamento e piloto */
    trajeto_guia(s, x[XN], x[XE], Vg, &o->g);
    piloto_comandos(s, t, x, Va, Vg, al, be, chi, -vn[2], qb, m, nochao, &o->g, &o->c, dx);
    const Cmd *c = &o->c;

    /* forcas e momentos */
    Aero ae; Prop pr;
    aero_calcula(a, Vr, w, rcg, h, c->de, c->da, c->dr, &ae);
    prop_calcula(a, Vr, w, rcg, x[XRPS], c->thr, &pr);
    double Fs[3], Ms[3];
    solo_calcula(s, x, R, rcg, c->dw, Fs, Ms, o->N);
    double F[3], M[3];
    for (int i = 0; i < 3; i++) {
        F[i] = ae.F[i] + pr.F[i] + Fs[i];
        M[i] = ae.M[i] + pr.M[i] + pr.Mgir[i] + Ms[i];
    }

    /* gravidade aparente no corpo para o liquido e para a carga */
    o->nz = -F[2] / (m * G0);              /* fator de carga (forca especifica em -z) */
    o->hdot = -vn[2];
    double aap[3], wr[3], wwr[3];
    cross(w, a->rt, wr); cross(w, wr, wwr);
    for (int i = 0; i < 3; i++) aap[i] = -F[i] / m - wwr[i];
    double Fl[3], Ml[3], Fc[3], Mc[3];
    carga_slosh(a, x, aap, r1, rcg, dx, Fl, Ml);
    carga_lapes(s, x, aap, rL, rcg, dx, Fc, Mc);
    for (int i = 0; i < 3; i++) { F[i] += Fl[i] + Fc[i]; M[i] += Ml[i] + Mc[i]; }

    /* peso */
    double sth = sin(x[XTHE]), cth = cos(x[XTHE]), sph = sin(x[XPHI]), cph = cos(x[XPHI]);
    F[0] += -m * G0 * sth; F[1] += m * G0 * cth * sph; F[2] += m * G0 * cth * cph;

    /* corpo rigido */
    dx[XU] = w[2] * VB[1] - w[1] * VB[2] + F[0] / m;
    dx[XV] = w[0] * VB[2] - w[2] * VB[0] + F[1] / m;
    dx[XW] = w[1] * VB[0] - w[0] * VB[1] + F[2] / m;
    double Iw[3], wIw[3], rhs[3], wd[3];
    for (int i = 0; i < 3; i++) Iw[i] = I[i][0] * w[0] + I[i][1] * w[1] + I[i][2] * w[2];
    cross(w, Iw, wIw);
    for (int i = 0; i < 3; i++) rhs[i] = M[i] - wIw[i];
    resolve3(I, rhs, wd);
    dx[XP] = wd[0]; dx[XQ] = wd[1]; dx[XR] = wd[2];
    dx[XPHI] = w[0] + (w[1] * sph + w[2] * cph) * tan(x[XTHE]);
    dx[XTHE] = w[1] * cph - w[2] * sph;
    dx[XPSI] = (w[1] * sph + w[2] * cph) / cth;
    dx[XN] = vn[0]; dx[XE] = vn[1]; dx[XD] = vn[2];
    dx[XRPS] = pr.drps;
    dx[XEN] = pr.P;

    /* ---------------- saidas ---------------- */
    o->Va = Va; o->Vg = Vg; o->alfa = al; o->beta = be; o->chi = chi; o->qbar = qb;
    double Vt = sqrt(dot(vn, vn));
    o->gama = Vt > 0.5 ? asin(-vn[2] / Vt) : 0.0;
    double ca = cos(al), sa = sin(al), cb = cos(be), sb = sin(be), qS = qb * a->Sref;
    if (qS > 1e-3) {
        o->CL = (-ae.F[2] * ca + ae.F[0] * sa) / qS;
        o->CD = -(ae.F[0] * ca * cb + ae.F[1] * sb + ae.F[2] * sa * cb) / qS;
        o->CDi = -(ae.Fi[0] * ca * cb + ae.Fi[1] * sb + ae.Fi[2] * sa * cb) / qS;
        o->CY = ae.F[1] / qS;
        for (int k = 0; k < NGR; k++) o->CLgr[k] = (-ae.Fg[k][2] * ca + ae.Fg[k][0] * sa) / qS;
        o->CLgr[2] = ae.Fg[2][1] / qS;           /* EV: forca lateral */
    } else {
        o->CL = o->CD = o->CDi = o->CY = 0.0;
        for (int k = 0; k < NGR; k++) o->CLgr[k] = 0.0;
    }
    o->razaoCL = ae.razaoCL;
    for (int i = 0; i < 3; i++) {
        for (int k = 0; k < NGR; k++) o->Mgr[k][i] = ae.Mg[k][i];
        o->Mhel[i] = pr.M[i]; o->Mgir[i] = pr.Mgir[i]; o->Mtr[i] = Ms[i];
        o->Mliq[i] = Ml[i]; o->Mcar[i] = Mc[i]; o->Mt[i] = M[i];
        o->rcg[i] = rcg[i]; o->Fs[i] = Fl[i]; o->W[i] = WN[i];
    }
    o->T = pr.T; o->Q = pr.Q; o->J = pr.J; o->I = pr.I; o->Ibat = pr.Ibat; o->Vbus = pr.Vbus; o->P = pr.P;
    o->m = m; o->Iyy = I[1][1]; o->ex = x[XEX]; o->ey = x[XEY];
    o->htail = 1e9;
    double xm = 0, nm = 0, xn = 0;
    for (int i = 0; i < a->nct; i++) {
        const Contato *ct = &a->ct[i];
        if (ct->tipo == 2) { double pc[3]; mulR(R, ct->r, pc); double hc = -(x[XD] + pc[2]); if (hc < o->htail) o->htail = hc; }
        if (ct->tipo == 1) { xm += ct->r[0]; nm += 1; }
        if (ct->tipo == 0) xn = ct->r[0];
    }
    /* reacoes no trem pelo artigo (Riboldi et al., eqs. 3-5): pista plana */
    double L = o->CL * qS;
    o->RN = m * G0 - pr.T * sin(x[XTHE] + a->phiT) - L;
    double chimw = rcg[0] - (nm > 0 ? xm / nm : 0.0), chinw = xn - rcg[0];
    double MG = ae.M[1], Gam = pr.M[1];
    o->Rnw = (o->RN * chimw - (MG + Gam)) / (chimw + chinw);
    o->Rmw = o->RN - o->Rnw;
}

void dinamica_rk4(const Sim *s, double t, double *x, double h)
{
    double k1[NX], k2[NX], k3[NX], k4[NX], xt[NX];
    int i;
    dinamica_f(s, t, x, k1, NULL);
    for (i = 0; i < NX; i++) xt[i] = x[i] + 0.5 * h * k1[i];
    dinamica_f(s, t + 0.5 * h, xt, k2, NULL);
    for (i = 0; i < NX; i++) xt[i] = x[i] + 0.5 * h * k2[i];
    dinamica_f(s, t + 0.5 * h, xt, k3, NULL);
    for (i = 0; i < NX; i++) xt[i] = x[i] + h * k3[i];
    dinamica_f(s, t + h, xt, k4, NULL);
    for (i = 0; i < NX; i++) x[i] += h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]);
}
