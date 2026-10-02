/*
 * estado.c -- checkpoint da simulacao
 *
 * Guarda tudo o que define o instante (vetor de estados, tempo, segmento,
 * modos do piloto, eventos ja ocorridos, carga em queda) num arquivo de
 * texto "chave valores". Os PARAMETROS nao vao junto: ao retomar, eles vem
 * da configuracao nova, e e assim que o Python muda as etapas seguintes
 * (raio de curva, ponto do LAPES, ganhos...) sem refazer o que ja passou.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "modelo.h"

#define EV_CAMPOS(X) X(tR) X(tRot) X(nRot) X(tLO) X(nLO) X(VLO) X(thLO) X(tHt) X(nHt) X(VHt) X(gHt) \
    X(hcmin) X(razao_dec) X(razao_mis) X(qpico_dec) X(Ipico) X(E) X(Edec) X(tdrop) X(ndrop) X(hdrop) \
    X(tsolto) X(pk_n) X(pk_e) X(pk_t) X(tg) X(tTD) X(nTD) X(nPara) X(tfim) X(quicou) X(completou) X(parou)

int estado_salva(const char *arq, const Corrida *c)
{
    FILE *f = fopen(arq, "w");
    if (!f) { perror(arq); return -1; }
    const Sim *s = &c->s;
    fprintf(f, "t %.17g\nx", c->t);
    for (int i = 0; i < NX; i++) fprintf(f, " %.17g", c->x[i]);
    fprintf(f, "\nseg %d\nfreios %d\nautop %d\ndecolou %d\npousou %d\nflare %d\nextraindo %d\nsolto %d\n",
            s->seg, s->freios, s->autop, s->decolou, s->pousou, s->flare, s->extraindo, s->solto);
    fprintf(f, "ev_feito");
    for (int i = 0; i < MAXEV; i++) fprintf(f, " %d", s->ev_feito[i]);
    fprintf(f, "\ntR_sim %.17g\nh_solo %.17g\ntg_sim %.17g\npkvoo %d\npk", s->tR, s->h_solo, s->tg, c->pkvoo);
    for (int i = 0; i < 6; i++) fprintf(f, " %.17g", c->pk[i]);
    fprintf(f, "\n");
#define ESC(k) fprintf(f, "ev_" #k " %.17g\n", c->v.k);
    EV_CAMPOS(ESC)
#undef ESC
    fclose(f);
    return 0;
}

int estado_carrega(const char *arq, Corrida *c)
{
    FILE *f = fopen(arq, "r");
    if (!f) { perror(arq); return -1; }
    char linha[4096];
    Sim *s = &c->s;
    while (fgets(linha, sizeof linha, f)) {
        char *tok = strtok(linha, " \t\r\n");
        if (!tok) continue;
        char *r = strtok(NULL, "\n");
        if (!r) r = "";
        if (!strcmp(tok, "t")) c->t = atof(r);
        else if (!strcmp(tok, "x")) { char *p = r; for (int i = 0; i < NX; i++) c->x[i] = strtod(p, &p); }
        else if (!strcmp(tok, "seg")) s->seg = atoi(r);
        else if (!strcmp(tok, "freios")) s->freios = atoi(r);
        else if (!strcmp(tok, "autop")) s->autop = atoi(r);
        else if (!strcmp(tok, "decolou")) s->decolou = atoi(r);
        else if (!strcmp(tok, "pousou")) s->pousou = atoi(r);
        else if (!strcmp(tok, "flare")) s->flare = atoi(r);
        else if (!strcmp(tok, "extraindo")) s->extraindo = atoi(r);
        else if (!strcmp(tok, "solto")) s->solto = atoi(r);
        else if (!strcmp(tok, "ev_feito")) { char *p = r; for (int i = 0; i < MAXEV; i++) s->ev_feito[i] = (int)strtol(p, &p, 10); }
        else if (!strcmp(tok, "tR_sim")) s->tR = atof(r);
        else if (!strcmp(tok, "h_solo")) s->h_solo = atof(r);
        else if (!strcmp(tok, "tg_sim")) s->tg = atof(r);
        else if (!strcmp(tok, "pkvoo")) c->pkvoo = atoi(r);
        else if (!strcmp(tok, "pk")) { char *p = r; for (int i = 0; i < 6; i++) c->pk[i] = strtod(p, &p); }
#define LE(k) else if (!strcmp(tok, "ev_" #k)) c->v.k = atof(r);
        EV_CAMPOS(LE)
#undef LE
    }
    fclose(f);
    return 0;
}
