/*
 * modelo.h -- tipos e interfaces do simulador de missao (6GDL)
 *
 * Cada subsistema mora no seu .c:
 *   cfg.c        leitura do arquivo de configuracao gerado pelo Python
 *   util.c       vetores, matrizes e saturacoes
 *   ambiente.c   vento e rajada
 *   aero.c       superficies sustentadoras (asa, EH, EV) e fuselagem
 *   propulsao.c  helice (tabela) + motor BLDC + bateria
 *   solo.c       trem de pouso e ponto de cauda
 *   carga.c      massa, CG, inercia, sloshing e LAPES
 *   trajeto.c    segmentos do percurso e guiamento
 *   piloto.c     piloto automatico
 *   dinamica.c   equacao mestre f(t,x) e RK4
 *   registro.c   arquivos de saida
 *   main.c       modos: missao, decolagem e polar
 */
#ifndef MODELO_H
#define MODELO_H

#include <stdio.h>

#define PI     3.14159265358979323846
#define G0     9.80665
#define DEG    (PI / 180.0)
#define MAXSUP 10
#define MAXCT  6
#define MAXSEG 16
#define MAXHEL 64
#define MAXEV  8
#define NGR    4          /* grupos aerodinamicos: asa, EH, EV, fuselagem */

/* vetor de estados */
enum { XN, XE, XD, XPHI, XTHE, XPSI, XU, XV, XW, XP, XQ, XR,
       XRPS,                        /* rotacao do motor (rps)             */
       XEX, XEY, XEXD, XEYD,        /* sloshing: angulos e taxas          */
       XSL, XSLD,                   /* LAPES: deslizamento da carga       */
       XIH, XIV, XITH, XIE,         /* integradores do piloto             */
       XHR,                         /* altura de referencia filtrada      */
       XPHC,                        /* inclinacao pedida filtrada         */
       XEN,                         /* energia tirada da bateria (J)      */
       NX };

/* superficie sustentadora: meia asa, EH ou EV */
typedef struct {
    char nome[24];
    int grupo;            /* 0 asa, 1 EH, 2 EV                               */
    int ctrl;             /* 0 nenhum, 1 aileron, 2 profundor, 3 leme        */
    int vertical;         /* 1: normal apontando para +y (EV)                */
    int lado;             /* +1 direita, -1 esquerda, 0 centro               */
    int downwash;         /* 1: sente o downwash da asa                      */
    double r[3];          /* centro aerodinamico no corpo (m)                */
    double S, c, AR, e;   /* area, corda, alongamento, Oswald                */
    double diedro, incid; /* rad                                             */
    double CLa, CL0, CLmax, CD0, Cmac;
    double tau, sinal;    /* efetividade do comando e sinal                  */
    double eta;           /* razao de pressao dinamica                       */
    double eps0, depsda;  /* downwash: eps = eps0 + depsda * alfa            */
    /* calculados na inicializacao */
    double a0, ex[3], ey[3], ez[3];
} Superficie;

/* ponto de contato com o solo */
typedef struct {
    double r[3], k, c;
    int tipo;             /* 0 bequilha (direcionavel), 1 principal (freio), 2 cauda */
} Contato;

/* segmento do percurso */
typedef struct {
    char nome[32];
    int arco;
    double n0, e0, chi0, L;     /* inicio, rumo inicial, comprimento        */
    double cn, ce, R, lam;      /* arco: centro, raio, sentido (+1 direita) */
    double h0, h1, V0, V1;      /* altura e velocidade no inicio e no fim   */
    int decolagem, pouso;
    double folga;               /* pouso: toca a folga metros antes do fim */
} Segmento;

typedef struct { int tipo; int seg; double s; } Evento;   /* tipo 0 LAPES, 1 rajada */

typedef struct {
    /* massa e inercia da aeronave seca (sobre o ponto O) */
    double m_seca, Ixx, Iyy, Izz, Ixz;
    double r_seca[3];      /* CG da aeronave seca em relacao a O (mexe no x_CG) */
    /* referencias aerodinamicas */
    double Sref, cref, bref, Mst;
    Superficie sup[MAXSUP]; int nsup;
    double fus_CDS, fus_Cma, fus_Cnb, fus_CYb, fus_r[3];
    /* helice e motor */
    double hel_J[MAXHEL], hel_CT[MAXHEL], hel_CP[MAXHEL]; int nhel;
    double D, Ip, Jm, phiT, psiT, rp[3], sentido;
    double Kv, Rm, B, tauc, Imax, Voc, Rint;
    /* solo */
    Contato ct[MAXCT]; int nct;
    double mu_r, mu_lat, mu_freio, mu_cauda, mu_pouso;
    /* tanque (sloshing) */
    double rt[3], Rtq, htq, rho_liq, zeta_s; int slosh;
    double mliq, m0, m1, l1, w1;            /* calculados */
    /* LAPES */
    double mL, rL[3], baia, Fext_g, mu_b, CdS_par;
    /* ambiente */
    double rho, Vw10, psiw, chiw, hw_ref, Tg, Ug[3]; int rajada;
    /* percurso */
    Segmento sg[MAXSEG]; int nseg;
    Evento ev[MAXEV]; int nev;
    /* decolagem (Riboldi et al.) */
    double VR, sR, de0, de1, taxa_de, ht, taxa_acel, h_fim_dec;   /* sR > 0: puxa o profundor em n = sR */
    /* piloto automatico */
    double ap_CL0, ap_CLa, alfa_max, g_sobe, g_desce, Khr, Kvs;
    double Kn_h, Kn_hd, Kn_ih, Kae, KIa, Kfn, Lorb, tlead;
    double Kth_h, Kth_hd, Kth_ih, Kthe, Kqe, KIth;
    double KV, KIV, KHT, Dtrim;
    double Kchi, kvf, chi_inf, korb, phimax, Kphia, Kpa, Kbeta, tau_phi, pmax_cmd;
    double Ky, Ki, Kpsi, Kr, Kbeq;
    double hflare, thflare, tau_flare, Kflare;
    double kCL;            /* limite de C_L/C_Lmax da asa (desempenho) */
    /* integracao e registro */
    double dt, tmax, dtlog, dtsolo, tsolo;
    /* parada para checkpoint: no inicio do segmento para_seg, em para_t,
     * ou quando o piloto automatico liga (para_autop) */
    double para_seg, para_t; int para_autop;
    int sem_carga;         /* 1: comeca sem a carga LAPES */
} Param;

/* estado discreto da simulacao (muda so entre passos) */
typedef struct {
    Param a;
    int seg, freios, autop, decolou, pousou, flare, extraindo, solto;
    int ev_feito[MAXEV];
    double tR, h_solo, tg;
} Sim;

/* eventos e medidas acumuladas de uma missao */
typedef struct {
    double tR, tRot, nRot, tLO, nLO, VLO, thLO, tHt, nHt, VHt, gHt;
    double hcmin, razao_dec, razao_mis, qpico_dec, Ipico, E, Edec;
    double tdrop, ndrop, hdrop, tsolto, pk_n, pk_e, pk_t, tg, tTD, nTD, nPara, tfim;
    double quicou, completou, parou;
} Eventos;

/* tudo o que define o instante da simulacao (checkpoint) */
typedef struct {
    Sim s;                  /* Param dentro de s.a NAO e salvo: vem da nova configuracao */
    double x[NX], t;
    Eventos v;
    double pk[6]; int pkvoo;
} Corrida;

/* saida do guiamento */
typedef struct { double s, ect, chip, chid, phiff, hseg, Vseg; } Guia;

/* comandos */
typedef struct { double thr, de, da, dr, dw, thc, alc, phic, href, hdref; int alim; } Cmd;

/* resultado da aerodinamica */
typedef struct {
    double F[3], M[3];                 /* total no CG (corpo)               */
    double Fg[NGR][3], Mg[NGR][3];     /* por grupo                         */
    double Fi[3];                      /* parte induzida do arrasto         */
    double razaoCL;                    /* max CL/CLmax nas meias asas       */
} Aero;

/* resultado da propulsao */
typedef struct { double F[3], M[3], Mgir[3], T, Q, J, I, Ibat, Vbus, P, drps; } Prop;

/* tudo o que vai para o registro */
typedef struct {
    Guia g; Cmd c;
    double Va, Vg, alfa, beta, gama, chi, qbar;
    double CL, CD, CDi, CY, CLgr[NGR], razaoCL;
    double Mgr[NGR][3], Mhel[3], Mgir[3], Mtr[3], Mliq[3], Mcar[3], Mt[3];
    double T, Q, J, I, Ibat, Vbus, P;
    double N[MAXCT], htail, RN, Rnw, Rmw;
    double m, rcg[3], Iyy, ex, ey, Fs[3];
    double W[3];
    double hdot, nz;        /* razao de subida e fator de carga */
} Saida;

/* ---- utilitarios (util.c) ---- */
double sat(double x, double l);
double lim(double x, double lo, double hi);
double sgn(double x);
double wrap(double a);
void cross(const double *a, const double *b, double *c);
double dot(const double *a, const double *b);
void mulR(double R[3][3], const double *v, double *o);
void mulRT(double R[3][3], const double *v, double *o);
void rotacao(const double *x, double R[3][3]);
void resolve3(double A[3][3], const double *b, double *x);
double sigma_estol(double al, double a0, double M);

/* ---- modulos ---- */
int  cfg_le(Param *a, const char *arq);
int  cfg_atribui(Param *a, const char *chave, const char *valor);
void cfg_padrao(Param *a);
void ambiente_vento(const Sim *s, double t, double h, double *W);
void aero_inicia(Param *a);
void aero_calcula(const Param *a, const double *Vr, const double *w, const double *rcg, double h,
                  double de, double da, double dr, Aero *o);
void prop_calcula(const Param *a, const double *Vr, const double *w, const double *rcg,
                  double rps, double thr, Prop *o);
void solo_calcula(const Sim *s, const double *x, double R[3][3], const double *rcg, double dw,
                  double *F, double *M, double *N);
void carga_inicia(Param *a);
void carga_massa(const Sim *s, const double *x, double *m, double *rcg, double I[3][3],
                 double *r1, double *rL);
void carga_slosh(const Param *a, const double *x, const double *aap, const double *r1,
                 const double *rcg, double *dx, double *F, double *M);
void carga_lapes(const Sim *s, const double *x, const double *aap, const double *rL,
                 const double *rcg, double *dx, double *F, double *M);
void trajeto_guia(const Sim *s, double n, double e, double Vg, Guia *g);
void piloto_comandos(const Sim *s, double t, const double *x, double Va, double Vg, double al,
                     double be, double chi, double hdot, double qb, double m, int nochao,
                     const Guia *g, Cmd *c, double *dx);
void dinamica_f(const Sim *s, double t, const double *x, double *dx, Saida *o);
void dinamica_rk4(const Sim *s, double t, double *x, double h);
void registro_cabecalho(FILE *f, const Sim *s);
void registro_linha(FILE *f, const Sim *s, double t, const double *x, const Saida *o);
int  estado_salva(const char *arq, const Corrida *c);
int  estado_carrega(const char *arq, Corrida *c);
int  desempenho(const Sim *s, const char *pref);

#endif
