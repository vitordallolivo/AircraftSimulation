/*
 * registro.c -- arquivo de saida com cabecalho de nomes (lido pelo Python)
 * Angulos em graus; momentos em N m; posicoes em m.
 */
#include <stdio.h>
#include "modelo.h"

#define R2D (180.0 / PI)

static int cab;
static FILE *saida;
static void col(const char *nome, double v)
{
    if (cab) fprintf(saida, "%s ", nome); else fprintf(saida, "%.6g ", v);
}

static void escreve(const Sim *s, double t, const double *x, const Saida *o)
{
    const char *ax = "LMN";
    const char *gr[NGR] = { "asa", "eh", "ev", "fus" };
    char nm[24];
    col("t", t); col("seg", s->seg);
    col("n", x[XN]); col("e", x[XE]); col("h", -x[XD]);
    col("phi", x[XPHI] * R2D); col("theta", x[XTHE] * R2D); col("psi", x[XPSI] * R2D);
    col("p", x[XP] * R2D); col("q", x[XQ] * R2D); col("r", x[XR] * R2D);
    col("Va", o->Va); col("Vg", o->Vg); col("alfa", o->alfa * R2D); col("beta", o->beta * R2D);
    col("gama", o->gama * R2D); col("chi", o->chi * R2D);
    col("s", o->g.s); col("ect", o->g.ect); col("hseg", o->g.hseg); col("href", o->c.href); col("Vref", o->g.Vseg);
    col("thc", o->c.thc * R2D); col("alc", o->c.alc * R2D); col("phic", o->c.phic * R2D);
    col("CL", o->CL); col("CD", o->CD); col("CDi", o->CDi); col("CY", o->CY);
    col("CLasa", o->CLgr[0]); col("CLeh", o->CLgr[1]); col("CYev", o->CLgr[2]); col("CLfus", o->CLgr[3]);
    col("razaoCL", o->razaoCL);
    col("T", o->T); col("Q", o->Q); col("J", o->J); col("I", o->I); col("Ibat", o->Ibat);
    col("Vbus", o->Vbus); col("P", o->P); col("E", x[XEN] / 3600.0); col("rpm", x[XRPS] * 60.0);
    col("thr", o->c.thr); col("de", o->c.de * R2D); col("da", o->c.da * R2D); col("dr", o->c.dr * R2D);
    col("dw", o->c.dw * R2D);
    /* reacoes: TDN = trem do nariz, TDP = trem principal (de pouso), cauda */
    double tdn = 0, tdp = 0;
    for (int i = 0; i < s->a.nct; i++) {
        const Contato *ct = &s->a.ct[i];
        const char *base = ct->tipo == 0 ? "TDN" : ct->tipo == 1 ? (ct->r[1] < 0 ? "TDPe" : "TDPd") : "cauda";
        snprintf(nm, sizeof nm, "%s%s", base, (ct->tipo == 0 && i > 0) ? "2" : "");
        col(nm, o->N[i]);
        if (ct->tipo == 0) tdn += o->N[i];
        if (ct->tipo == 1) tdp += o->N[i];
    }
    col("TDN_tot", tdn); col("TDP", tdp);
    col("htail", o->htail); col("RN_art", o->RN); col("TDN_art", o->Rnw); col("TDP_art", o->Rmw);
    col("hdot", o->hdot); col("nz", o->nz); col("alim", o->c.alim);
    col("m", o->m); col("xcg", o->rcg[0] * 100.0); col("zcg", o->rcg[2] * 100.0); col("Iyy", o->Iyy);
    col("ex", o->ex * R2D); col("ey", o->ey * R2D); col("Fsx", o->Fs[0]); col("Fsy", o->Fs[1]);
    col("sL", x[XSL]);
    for (int i = 0; i < 3; i++) {
        for (int k = 0; k < NGR; k++) { snprintf(nm, sizeof nm, "%c%s", ax[i], gr[k]); col(nm, o->Mgr[k][i]); }
        snprintf(nm, sizeof nm, "%chel", ax[i]); col(nm, o->Mhel[i]);
        snprintf(nm, sizeof nm, "%cgir", ax[i]); col(nm, o->Mgir[i]);
        snprintf(nm, sizeof nm, "%ctr", ax[i]); col(nm, o->Mtr[i]);
        snprintf(nm, sizeof nm, "%cliq", ax[i]); col(nm, o->Mliq[i]);
        snprintf(nm, sizeof nm, "%ccar", ax[i]); col(nm, o->Mcar[i]);
        snprintf(nm, sizeof nm, "%ct", ax[i]); col(nm, o->Mt[i]);
    }
    col("Wn", o->W[0]); col("We", o->W[1]); col("Wd", o->W[2]);
    fprintf(saida, "\n");
}

void registro_cabecalho(FILE *f, const Sim *s)
{
    static double x0[NX]; static Saida o0;
    saida = f; cab = 1;
    escreve(s, 0, x0, &o0);
}

void registro_linha(FILE *f, const Sim *s, double t, const double *x, const Saida *o)
{
    saida = f; cab = 0;
    escreve(s, t, x, o);
}
