/*
 * main.c -- simulador de missao 6GDL (monomotor convencional)
 *
 * uso: missao6gdl <modo> <arquivo.cfg> <prefixo> [opcoes] [chave=valor ...]
 *   missao      missao (ou um trecho): <prefixo>_traj.dat, _solo.dat, _pacote.dat, _eventos.txt
 *   decolagem   so a decolagem (ate h_fim_dec acima do chao): eventos na saida padrao
 *   polar       curvas estaticas: <prefixo>_polar.dat e <prefixo>_polarb.dat
 *   desempenho  pontos de desempenho por velocidade: <prefixo>_desempenho.dat
 * opcoes:
 *   --carrega arq   comeca do checkpoint arq (pula o assentamento no chao)
 *   --salva arq     grava o checkpoint quando parar (para_seg, para_t ou para_autop)
 * As sobrescritas chave=valor valem para os escalares do arquivo (angulos em graus).
 *
 * Compilar: make
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "modelo.h"

static void escreve_eventos(FILE *f, const Eventos *v)
{
#define K(nome) fprintf(f, #nome "=%.6g\n", (double)v->nome)
    K(tR); K(tRot); K(nRot); K(tLO); K(nLO); K(VLO); K(thLO); K(tHt); K(nHt); K(VHt); K(gHt);
    K(hcmin); K(razao_dec); K(razao_mis); K(qpico_dec); K(Ipico); K(E); K(Edec);
    K(tdrop); K(ndrop); K(hdrop); K(tsolto); K(pk_n); K(pk_e); K(pk_t); K(tg); K(tTD); K(nTD);
    K(nPara); K(tfim); K(quicou); K(completou); K(parou);
#undef K
}

static void sincroniza_integradores(Sim *s, double *x, double t, double de_antes)
{
    /* liga o piloto automatico sem degrau: profundor e acelerador continuam de onde estavam */
    const Param *a = &s->a;
    Saida o; double dx[NX];
    x[XITH] = 0.0; x[XIH] = 0.0;
    dinamica_f(s, t, x, dx, &o);
    double sph = sin(x[XPHI]), cph = cos(x[XPHI]);
    double qref = G0 / (o.Va > 3.0 ? o.Va : 3.0) * sph * sph / cph;
    x[XITH] = a->KIa != 0.0 ? (de_antes - a->Kae * (o.alfa - o.c.alc) - a->Kqe * (x[XQ] - qref)) / a->KIa : 0.0;
    x[XIV] = a->KIV != 0.0 ? (1.0 - a->Dtrim - a->KV * (o.g.Vseg - o.Va) - a->KHT * (o.c.href + x[XD])) / a->KIV : 0.0;
}

/* aeronave parada na cabeceira, freada, ate assentar no trem */
static void inicio_no_chao(Corrida *c)
{
    Sim *s = &c->s;
    const Param *a = &s->a;
    memset(c->x, 0, sizeof c->x);
    memset(&c->v, 0, sizeof c->v);
    Eventos *v = &c->v;
    v->tR = v->tRot = v->tLO = v->tHt = v->tdrop = v->tsolto = v->tg = v->tTD = -1.0;
    v->hcmin = 1e9;
    s->seg = 0; s->tR = -1.0; s->tg = -1.0; s->freios = 1; s->solto = a->sem_carga;
    double zr = 0.0;
    for (int i = 0; i < a->nct; i++) if (a->ct[i].tipo == 1) zr = a->ct[i].r[2];
    c->x[XD] = -zr; c->x[XRPS] = 1.0;
    for (double t = -3.0; t < -1e-9; t += a->dt) dinamica_rk4(s, t, c->x, a->dt);
    double *x = c->x;
    x[XN] = x[XE] = x[XPSI] = 0.0; x[XU] = x[XV] = x[XP] = x[XR] = 0.0;
    for (int i = XIH; i <= XEN; i++) x[i] = 0.0;
    s->h_solo = -x[XD];
    x[XHR] = s->h_solo;
    s->freios = 0;
    c->t = 0.0;
    c->pkvoo = 0;
}

static int simula(Corrida *c, int so_decolagem, const char *pref, const char *salva)
{
    Sim *s = &c->s;
    const Param *a = &s->a;
    double *x = c->x, dx[NX];
    Eventos *v = &c->v;
    Saida o;
    FILE *ft = NULL, *fs = NULL, *fp = NULL;
    char nome[512];
    if (!so_decolagem) {
        snprintf(nome, sizeof nome, "%s_traj.dat", pref); ft = fopen(nome, "w");
        snprintf(nome, sizeof nome, "%s_solo.dat", pref); fs = fopen(nome, "w");
        snprintf(nome, sizeof nome, "%s_pacote.dat", pref); fp = fopen(nome, "w");
        if (!ft || !fs || !fp) { perror(pref); return 1; }
        registro_cabecalho(ft, s); registro_cabecalho(fs, s);
        fprintf(fp, "t n e h\n");
    }
    double t = c->t, prox = t, proxs = t;
    double *pk = c->pk;
    v->parou = 0;

    for (long it = 0;; it++) {
        dinamica_f(s, t, x, dx, &o);
        double h = -x[XD];
        int contato = 0, nariz = 0, principal = 0;
        for (int i = 0; i < a->nct; i++) {
            if (o.N[i] > 0.0) contato = 1;
            if (a->ct[i].tipo == 0 && o.N[i] > 0.0) nariz = 1;
            if (a->ct[i].tipo == 1 && o.N[i] > 0.0) principal = 1;
        }
        const Segmento *sg = &a->sg[s->seg];

        /* ---- decolagem: profundor por velocidade (VR) ou por distancia (sR) ---- */
        int puxa = a->sR > 0.0 ? x[XN] >= a->sR : o.Va >= a->VR;
        if (!s->autop && s->tR < 0.0 && puxa) { s->tR = t; v->tR = t; }
        if (sg->decolagem && v->tRot < 0.0 && !nariz && t > 0.05) { v->tRot = t; v->nRot = x[XN]; }
        if (!s->decolou && !contato && h > s->h_solo + 0.005) {
            s->decolou = 1; v->tLO = t; v->nLO = x[XN]; v->VLO = o.Va; v->thLO = x[XTHE] / DEG;
        }
        /* referencia de altura com catraca: se o aviao ja passou da referencia na direcao do
         * alvo do segmento, a referencia vem junto (nao devolve altura ganha rumo ao alvo) */
        if (s->autop && !s->flare && !s->pousou && !sg->pouso) {
            if (o.g.hseg > x[XHR] && h > x[XHR]) x[XHR] = fmin(h, o.g.hseg);
            else if (o.g.hseg < x[XHR] && h < x[XHR]) x[XHR] = fmax(h, o.g.hseg);
        }
        int ligou = 0;
        if (s->decolou && !s->autop && h >= s->h_solo + a->ht) {
            s->autop = 1; x[XHR] = h; ligou = 1;
            sincroniza_integradores(s, x, t, o.c.de);
            v->tHt = t; v->nHt = x[XN]; v->VHt = o.Va; v->gHt = o.gama / DEG;
        }
        if (sg->decolagem) {
            if (o.htail < v->hcmin) v->hcmin = o.htail;
            if (o.razaoCL > v->razao_dec && o.Va > 4.0) v->razao_dec = o.razaoCL;
            if (fabs(x[XQ]) / DEG > v->qpico_dec) v->qpico_dec = fabs(x[XQ]) / DEG;
        }
        if (s->decolou && !s->pousou && contato && !sg->pouso) v->quicou = 1;
        if (o.razaoCL > v->razao_mis && o.Va > 4.0) v->razao_mis = o.razaoCL;
        if (o.Ibat > v->Ipico) v->Ipico = o.Ibat;

        /* ---- percurso e eventos ---- */
        int trocou = 0;
        if (!sg->pouso && s->seg < a->nseg - 1 && o.g.s >= sg->L) {
            if (sg->decolagem) v->Edec = x[XEN] / 3600.0;
            s->seg++; trocou = 1;
        }
        for (int k = 0; k < a->nev && !trocou; k++) {
            const Evento *e = &a->ev[k];
            if (s->ev_feito[k] || s->seg != e->seg || o.g.s < e->s) continue;
            s->ev_feito[k] = 1;
            if (e->tipo == 1) { s->tg = t; v->tg = t; }
            else if (!s->solto) { s->extraindo = 1; v->tdrop = t; v->ndrop = x[XN]; v->hdrop = h; }
        }
        if (s->extraindo && !s->solto && x[XSL] >= a->baia) {
            s->solto = 1; v->tsolto = t;
            double R[3][3]; rotacao(x, R);
            double rL[3] = { a->rL[0] - x[XSL], a->rL[1], a->rL[2] }, pc[3], w[3] = { x[XP], x[XQ], x[XR] };
            double wr[3], vb[3], vn[3];
            mulR(R, rL, pc); cross(w, rL, wr);
            vb[0] = x[XU] + wr[0] - x[XSLD]; vb[1] = x[XV] + wr[1]; vb[2] = x[XW] + wr[2];
            mulR(R, vb, vn);
            pk[0] = x[XN] + pc[0]; pk[1] = x[XE] + pc[1]; pk[2] = x[XD] + pc[2];
            pk[3] = vn[0]; pk[4] = vn[1]; pk[5] = vn[2]; c->pkvoo = 1;
        }
        if (c->pkvoo) {                    /* carga com paraquedas */
            double W[3]; ambiente_vento(s, t, -pk[2], W);
            double vr[3] = { pk[3] - W[0], pk[4] - W[1], pk[5] - W[2] }, V = sqrt(dot(vr, vr));
            for (int i = 0; i < 3; i++) {
                double acc = -0.5 * a->rho * V * a->CdS_par * vr[i] / a->mL + (i == 2 ? G0 : 0.0);
                pk[3 + i] += acc * a->dt; pk[i] += pk[3 + i] * a->dt;
            }
            if (fp && it % 20 == 0) fprintf(fp, "%.3f %.4f %.4f %.4f\n", t, pk[0], pk[1], -pk[2]);
            if (pk[2] >= 0.0) { c->pkvoo = 0; v->pk_n = pk[0]; v->pk_e = pk[1]; v->pk_t = t; }
        }
        if (sg->pouso && h - s->h_solo < a->hflare) s->flare = 1;
        if (sg->pouso && !s->pousou && principal) { s->pousou = 1; v->tTD = t; v->nTD = x[XN]; }

        /* ---- registro ---- */
        if (ft && t >= prox - 1e-9) { registro_linha(ft, s, t, x, &o); prox += a->dtlog; }
        if (fs && t <= a->tsolo && t >= proxs - 1e-9) { registro_linha(fs, s, t, x, &o); proxs += a->dtsolo; }

        /* ---- paradas ---- */
        int para = (a->para_seg >= 0 && s->seg == (int)a->para_seg && trocou) ||
                   (a->para_t > 0 && t >= a->para_t) || (a->para_autop && ligou);
        if (para) { v->parou = 1; break; }
        if (s->pousou && o.Vg < 0.3) { v->nPara = x[XN]; v->completou = 1; break; }
        if (so_decolagem && s->autop && h >= s->h_solo + a->h_fim_dec) { v->completou = 1; break; }
        if (t >= a->tmax || h < -1.0) break;
        dinamica_rk4(s, t, x, a->dt);
        t += a->dt;
    }
    c->t = t;
    v->tfim = t; v->E = x[XEN] / 3600.0;
    if (ft) { fclose(ft); fclose(fs); fclose(fp); }
    if (salva && estado_salva(salva, c) != 0) return 1;
    if (so_decolagem) escreve_eventos(stdout, v);
    else {
        snprintf(nome, sizeof nome, "%s_eventos.txt", pref);
        FILE *fe = fopen(nome, "w");
        if (fe) { escreve_eventos(fe, v); fclose(fe); }
    }
    return 0;
}

/* curvas estaticas: alfa (beta = 0) e beta (alfa fixo), sem rotacao */
static int polar(Sim *s, const char *pref)
{
    const Param *a = &s->a;
    double x[NX] = { 0 }, m, rcg[3], I[3][3], r1[3], rL[3];
    carga_massa(s, x, &m, rcg, I, r1, rL);
    double V = 12.0, w[3] = { 0, 0, 0 }, qS = 0.5 * a->rho * V * V * a->Sref;
    char nome[512];
    snprintf(nome, sizeof nome, "%s_polar.dat", pref);
    FILE *f = fopen(nome, "w");
    if (!f) { perror(nome); return 1; }
    fprintf(f, "alfa CL CD Cm CLasa CLeh Cm_dem10 Cm_dep10 CL_dem10 CL_dep10\n");
    for (double al = -10.0; al <= 30.0 + 1e-9; al += 0.25) {
        double Vr[3] = { V * cos(al * DEG), 0.0, V * sin(al * DEG) }, ca = cos(al * DEG), sa = sin(al * DEG);
        Aero ae, am, ap;
        aero_calcula(a, Vr, w, rcg, 50.0, 0.0, 0.0, 0.0, &ae);
        aero_calcula(a, Vr, w, rcg, 50.0, -10 * DEG, 0.0, 0.0, &am);
        aero_calcula(a, Vr, w, rcg, 50.0, 10 * DEG, 0.0, 0.0, &ap);
#define CLde(A) ((-(A).F[2] * ca + (A).F[0] * sa) / qS)
        fprintf(f, "%.2f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f\n", al, CLde(ae),
                -(ae.F[0] * ca + ae.F[2] * sa) / qS, ae.M[1] / (qS * a->cref),
                (-ae.Fg[0][2] * ca + ae.Fg[0][0] * sa) / qS, (-ae.Fg[1][2] * ca + ae.Fg[1][0] * sa) / qS,
                am.M[1] / (qS * a->cref), ap.M[1] / (qS * a->cref), CLde(am), CLde(ap));
#undef CLde
    }
    fclose(f);
    snprintf(nome, sizeof nome, "%s_polarb.dat", pref);
    f = fopen(nome, "w");
    fprintf(f, "beta CY Cl Cn\n");
    for (double be = -20.0; be <= 20.0 + 1e-9; be += 0.5) {
        double al = 4.0 * DEG, b = be * DEG;
        double Vr[3] = { V * cos(al) * cos(b), V * sin(b), V * sin(al) * cos(b) };
        Aero ae;
        aero_calcula(a, Vr, w, rcg, 50.0, 0.0, 0.0, 0.0, &ae);
        fprintf(f, "%.2f %.5f %.5f %.5f\n", be, ae.F[1] / qS, ae.M[0] / (qS * a->bref), ae.M[2] / (qS * a->bref));
    }
    fclose(f);
    printf("massa=%.4f\nxcg=%.5f\nzcg=%.5f\nmliq=%.4f\nm1=%.4f\nl1=%.5f\nf1=%.4f\n",
           m, rcg[0], rcg[2], a->mliq, a->m1, a->l1, a->w1 / (2 * PI));
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "uso: %s missao|decolagem|polar|desempenho arquivo.cfg prefixo "
                        "[--carrega arq] [--salva arq] [chave=valor ...]\n", argv[0]);
        return 1;
    }
    static Corrida c;
    memset(&c, 0, sizeof c);
    Param *a = &c.s.a;
    cfg_padrao(a);
    if (cfg_le(a, argv[2]) != 0) return 1;
    const char *carrega = NULL, *salva = NULL;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--carrega") && i + 1 < argc) { carrega = argv[++i]; continue; }
        if (!strcmp(argv[i], "--salva") && i + 1 < argc) { salva = argv[++i]; continue; }
        char *eq = strchr(argv[i], '=');
        if (!eq) continue;
        *eq = 0;
        if (cfg_atribui(a, argv[i], eq + 1) != 0) return 1;
    }
    aero_inicia(a);
    carga_inicia(a);
    if (!strcmp(argv[1], "polar")) return polar(&c.s, argv[3]);
    if (!strcmp(argv[1], "desempenho")) return desempenho(&c.s, argv[3]);
    if (carrega) { if (estado_carrega(carrega, &c) != 0) return 1; }
    else inicio_no_chao(&c);
    return simula(&c, !strcmp(argv[1], "decolagem"), argv[3], salva);
}
