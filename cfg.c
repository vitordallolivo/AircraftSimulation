/*
 * cfg.c -- leitura do arquivo de configuracao
 *
 * Formato (gerado pelo Python, uma linha por item, '#' comenta):
 *   chave v1 [v2 v3]                    escalar ou vetor
 *   superficie k=v k=v ...              asa, EH, EV
 *   contato    k=v ...                  trem e cauda
 *   segmento   k=v ...                  percurso
 *   evento     k=v ...                  LAPES e rajada
 *   helice     J=.. CT=.. CP=..         uma linha por ponto da tabela
 * Angulos sempre em graus no arquivo; aqui viram radianos.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "modelo.h"

typedef struct { const char *nome; size_t off; int n; double esc; int inteiro; } Campo;

#define FD(nm, campo, n, esc) { nm, offsetof(Param, campo), n, esc, 0 }
#define FI(nm, campo)         { nm, offsetof(Param, campo), 1, 1.0, 1 }

static const Campo campos[] = {
    FD("m_seca", m_seca, 1, 1), FD("Ixx", Ixx, 1, 1), FD("Iyy", Iyy, 1, 1), FD("Izz", Izz, 1, 1), FD("Ixz", Ixz, 1, 1), FD("r_seca", r_seca, 3, 1),
    FD("Sref", Sref, 1, 1), FD("cref", cref, 1, 1), FD("bref", bref, 1, 1), FD("Mst", Mst, 1, 1),
    FD("fus_CDS", fus_CDS, 1, 1), FD("fus_Cma", fus_Cma, 1, 1), FD("fus_Cnb", fus_Cnb, 1, 1),
    FD("fus_CYb", fus_CYb, 1, 1), FD("fus_r", fus_r, 3, 1),
    FD("D", D, 1, 1), FD("Ip", Ip, 1, 1), FD("Jm", Jm, 1, 1), FD("phiT", phiT, 1, DEG), FD("psiT", psiT, 1, DEG),
    FD("rp", rp, 3, 1), FD("sentido", sentido, 1, 1),
    FD("Kv", Kv, 1, 1), FD("Rm", Rm, 1, 1), FD("B", B, 1, 1), FD("tauc", tauc, 1, 1), FD("Imax", Imax, 1, 1),
    FD("Voc", Voc, 1, 1), FD("Rint", Rint, 1, 1),
    FD("mu_r", mu_r, 1, 1), FD("mu_lat", mu_lat, 1, 1), FD("mu_freio", mu_freio, 1, 1),
    FD("mu_cauda", mu_cauda, 1, 1), FD("mu_pouso", mu_pouso, 1, 1),
    FD("rt", rt, 3, 1), FD("Rtq", Rtq, 1, 1), FD("htq", htq, 1, 1), FD("rho_liq", rho_liq, 1, 1),
    FD("zeta_s", zeta_s, 1, 1), FI("slosh", slosh),
    FD("mL", mL, 1, 1), FD("rL", rL, 3, 1), FD("baia", baia, 1, 1), FD("Fext_g", Fext_g, 1, 1),
    FD("mu_b", mu_b, 1, 1), FD("CdS_par", CdS_par, 1, 1),
    FD("rho", rho, 1, 1), FD("Vw10", Vw10, 1, 1), FD("psiw", psiw, 1, DEG), FD("chiw", chiw, 1, DEG),
    FD("hw_ref", hw_ref, 1, 1), FD("Tg", Tg, 1, 1), FD("Ug", Ug, 3, 1), FI("rajada", rajada),
    FD("VR", VR, 1, 1), FD("sR", sR, 1, 1), FD("de0", de0, 1, DEG), FD("de1", de1, 1, DEG), FD("taxa_de", taxa_de, 1, DEG),
    FD("ht", ht, 1, 1), FD("taxa_acel", taxa_acel, 1, 1), FD("h_fim_dec", h_fim_dec, 1, 1),
    FD("ap_CL0", ap_CL0, 1, 1), FD("ap_CLa", ap_CLa, 1, 1), FD("alfa_max", alfa_max, 1, DEG),
    FD("g_sobe", g_sobe, 1, 1), FD("g_desce", g_desce, 1, 1), FD("Khr", Khr, 1, 1), FD("Kvs", Kvs, 1, 1),
    FD("Kn_h", Kn_h, 1, 1), FD("Kn_hd", Kn_hd, 1, 1), FD("Kn_ih", Kn_ih, 1, 1), FD("Kae", Kae, 1, 1), FD("KIa", KIa, 1, 1), FD("Kfn", Kfn, 1, 1), FD("Lorb", Lorb, 1, 1), FD("tlead", tlead, 1, 1),
    FD("Kth_h", Kth_h, 1, DEG), FD("Kth_hd", Kth_hd, 1, DEG), FD("Kth_ih", Kth_ih, 1, DEG),
    FD("Kthe", Kthe, 1, 1), FD("Kqe", Kqe, 1, 1), FD("KIth", KIth, 1, 1),
    FD("KV", KV, 1, 1), FD("KIV", KIV, 1, 1), FD("KHT", KHT, 1, 1), FD("Dtrim", Dtrim, 1, 1),
    FD("Kchi", Kchi, 1, 1), FD("kvf", kvf, 1, 1), FD("chi_inf", chi_inf, 1, DEG), FD("korb", korb, 1, 1),
    FD("phimax", phimax, 1, DEG), FD("Kphia", Kphia, 1, 1), FD("Kpa", Kpa, 1, 1), FD("Kbeta", Kbeta, 1, 1), FD("tau_phi", tau_phi, 1, 1), FD("pmax_cmd", pmax_cmd, 1, DEG),
    FD("Ky", Ky, 1, 1), FD("Ki", Ki, 1, 1), FD("Kpsi", Kpsi, 1, 1), FD("Kr", Kr, 1, 1), FD("Kbeq", Kbeq, 1, 1),
    FD("hflare", hflare, 1, 1), FD("thflare", thflare, 1, DEG), FD("tau_flare", tau_flare, 1, 1), FD("Kflare", Kflare, 1, DEG), FD("kCL", kCL, 1, 1),
    FD("dt", dt, 1, 1), FD("tmax", tmax, 1, 1), FD("dtlog", dtlog, 1, 1), FD("dtsolo", dtsolo, 1, 1),
    FD("tsolo", tsolo, 1, 1), FD("para_seg", para_seg, 1, 1), FD("para_t", para_t, 1, 1),
    FI("para_autop", para_autop), FI("sem_carga", sem_carga),
};
#define NCAMPOS ((int)(sizeof campos / sizeof campos[0]))

/* valores minimos para o programa rodar sem arquivo (o Python sobrescreve tudo) */
void cfg_padrao(Param *a)
{
    memset(a, 0, sizeof *a);
    a->rho = 1.225; a->Mst = 50.0; a->sentido = 1.0; a->hw_ref = 10.0; a->Tg = 1.0;
    a->dt = 1e-3; a->tmax = 400.0; a->dtlog = 0.02; a->dtsolo = 0.002; a->tsolo = 15.0;
    a->taxa_acel = 2.0; a->h_fim_dec = 6.0; a->Khr = 0.5; a->Kvs = 0.5;
    a->Kn_h = 0.065; a->Kn_hd = 0.13; a->Kn_ih = 0.01; a->Kae = 4.0; a->KIa = 4.0; a->Kfn = 1.2; a->Lorb = 50.0; a->tlead = 0.8;
    a->para_seg = -1.0; a->para_t = -1.0; a->kCL = 0.95;
    a->tau_phi = 0.3; a->pmax_cmd = 60.0 * DEG;
}

static int atribui_escalar(Param *a, const char *chave, char **vals, int nv)
{
    for (int i = 0; i < NCAMPOS; i++) {
        if (strcmp(campos[i].nome, chave) != 0) continue;
        if (campos[i].inteiro) { *(int *)((char *)a + campos[i].off) = atoi(vals[0]); return 0; }
        double *p = (double *)((char *)a + campos[i].off);
        for (int k = 0; k < campos[i].n && k < nv; k++) p[k] = atof(vals[k]) * campos[i].esc;
        return 0;
    }
    fprintf(stderr, "cfg: chave desconhecida '%s'\n", chave);
    return -1;
}

/* "chave=valor" (vetor: v1,v2,v3) -- usado nas sobrescritas da linha de comando */
int cfg_atribui(Param *a, const char *chave, const char *valor)
{
    char buf[256], *v[4]; int n = 0;
    snprintf(buf, sizeof buf, "%s", valor);
    for (char *t = strtok(buf, ","); t && n < 4; t = strtok(NULL, ",")) v[n++] = t;
    return atribui_escalar(a, chave, v, n);
}

static double kv_num(char **tok, int nt, const char *k, double padrao)
{
    size_t l = strlen(k);
    for (int i = 1; i < nt; i++)
        if (strncmp(tok[i], k, l) == 0 && tok[i][l] == '=') return atof(tok[i] + l + 1);
    return padrao;
}
static const char *kv_txt(char **tok, int nt, const char *k)
{
    size_t l = strlen(k);
    for (int i = 1; i < nt; i++)
        if (strncmp(tok[i], k, l) == 0 && tok[i][l] == '=') return tok[i] + l + 1;
    return "";
}

static void le_superficie(Param *a, char **t, int n)
{
    if (a->nsup >= MAXSUP) return;
    Superficie *s = &a->sup[a->nsup++];
    memset(s, 0, sizeof *s);
    snprintf(s->nome, sizeof s->nome, "%s", kv_txt(t, n, "nome"));
    s->grupo = (int)kv_num(t, n, "grupo", 0); s->ctrl = (int)kv_num(t, n, "ctrl", 0);
    s->vertical = (int)kv_num(t, n, "vertical", 0); s->lado = (int)kv_num(t, n, "lado", 0);
    s->downwash = (int)kv_num(t, n, "downwash", 0);
    s->r[0] = kv_num(t, n, "x", 0); s->r[1] = kv_num(t, n, "y", 0); s->r[2] = kv_num(t, n, "z", 0);
    s->S = kv_num(t, n, "S", 0); s->c = kv_num(t, n, "c", 0); s->AR = kv_num(t, n, "AR", 5);
    s->e = kv_num(t, n, "e", 0.8);
    s->diedro = kv_num(t, n, "diedro", 0) * DEG; s->incid = kv_num(t, n, "incid", 0) * DEG;
    s->CLa = kv_num(t, n, "CLa", 4.5); s->CL0 = kv_num(t, n, "CL0", 0); s->CLmax = kv_num(t, n, "CLmax", 1.2);
    s->CD0 = kv_num(t, n, "CD0", 0.01); s->Cmac = kv_num(t, n, "Cmac", 0);
    s->tau = kv_num(t, n, "tau", 0); s->sinal = kv_num(t, n, "sinal", 1); s->eta = kv_num(t, n, "eta", 1);
    s->eps0 = kv_num(t, n, "eps0", 0) * DEG; s->depsda = kv_num(t, n, "depsda", 0);
}

static void le_contato(Param *a, char **t, int n)
{
    if (a->nct >= MAXCT) return;
    Contato *c = &a->ct[a->nct++];
    c->tipo = (int)kv_num(t, n, "tipo", 1);
    c->r[0] = kv_num(t, n, "x", 0); c->r[1] = kv_num(t, n, "y", 0); c->r[2] = kv_num(t, n, "z", 0);
    c->k = kv_num(t, n, "k", 3000); c->c = kv_num(t, n, "c", 80);
}

static void le_segmento(Param *a, char **t, int n)
{
    if (a->nseg >= MAXSEG) return;
    Segmento *g = &a->sg[a->nseg++];
    memset(g, 0, sizeof *g);
    snprintf(g->nome, sizeof g->nome, "%s", kv_txt(t, n, "nome"));
    g->arco = (int)kv_num(t, n, "arco", 0);
    g->n0 = kv_num(t, n, "n0", 0); g->e0 = kv_num(t, n, "e0", 0); g->chi0 = kv_num(t, n, "chi0", 0) * DEG;
    g->L = kv_num(t, n, "L", 0); g->cn = kv_num(t, n, "cn", 0); g->ce = kv_num(t, n, "ce", 0);
    g->R = kv_num(t, n, "R", 0); g->lam = kv_num(t, n, "lam", 1);
    g->h0 = kv_num(t, n, "h0", 0); g->h1 = kv_num(t, n, "h1", 0);
    g->V0 = kv_num(t, n, "V0", 0); g->V1 = kv_num(t, n, "V1", 0);
    g->decolagem = (int)kv_num(t, n, "decolagem", 0); g->pouso = (int)kv_num(t, n, "pouso", 0);
    g->folga = kv_num(t, n, "folga", 0);
}

static void le_evento(Param *a, char **t, int n)
{
    if (a->nev >= MAXEV) return;
    Evento *e = &a->ev[a->nev++];
    e->tipo = strcmp(kv_txt(t, n, "tipo"), "rajada") == 0 ? 1 : 0;
    e->seg = (int)kv_num(t, n, "seg", 0); e->s = kv_num(t, n, "s", 0);
}

static void le_helice(Param *a, char **t, int n)
{
    if (a->nhel >= MAXHEL) return;
    a->hel_J[a->nhel] = kv_num(t, n, "J", 0);
    a->hel_CT[a->nhel] = kv_num(t, n, "CT", 0);
    a->hel_CP[a->nhel] = kv_num(t, n, "CP", 0);
    a->nhel++;
}

int cfg_le(Param *a, const char *arq)
{
    FILE *f = fopen(arq, "r");
    if (!f) { perror(arq); return -1; }
    char linha[1024];
    int erros = 0;
    while (fgets(linha, sizeof linha, f)) {
        char *c = strchr(linha, '#');
        if (c) *c = 0;
        char *tok[64]; int n = 0;
        for (char *t = strtok(linha, " \t\r\n"); t && n < 64; t = strtok(NULL, " \t\r\n")) tok[n++] = t;
        if (n == 0) continue;
        if (!strcmp(tok[0], "superficie")) le_superficie(a, tok, n);
        else if (!strcmp(tok[0], "contato")) le_contato(a, tok, n);
        else if (!strcmp(tok[0], "segmento")) le_segmento(a, tok, n);
        else if (!strcmp(tok[0], "evento")) le_evento(a, tok, n);
        else if (!strcmp(tok[0], "helice")) le_helice(a, tok, n);
        else if (n >= 2) erros += atribui_escalar(a, tok[0], tok + 1, n - 1) != 0;
    }
    fclose(f);
    return erros ? -1 : 0;
}
