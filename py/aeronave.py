"""Aeronave monomotora convencional (asa, EH, EV, fuselagem) e seus dados.

Tudo aqui vira o arquivo de configuracao lido pelo simulador em C.
Unidades SI; angulos em graus. Para outra aeronave, copie `padrao()` e
troque os numeros, ou altere o dicionario depois de criado.
"""
import math


def helmbold(a0, AR):
    """Inclinacao C_La de uma asa finita (por rad) a partir da do perfil a0."""
    k = a0 / (math.pi * AR)
    return a0 / (math.sqrt(1.0 + k * k) + k)


# APC 15x8E, 6000 rpm (catalogo do fabricante: J, C_T, C_P)
APC_15x8E = [
    (0.0000, 0.0896, 0.0299), (0.0234, 0.0883, 0.0303), (0.0468, 0.0869, 0.0307), (0.0701, 0.0853, 0.0310),
    (0.0935, 0.0836, 0.0314), (0.1169, 0.0818, 0.0316), (0.1403, 0.0799, 0.0319), (0.1637, 0.0778, 0.0320),
    (0.1871, 0.0756, 0.0321), (0.2104, 0.0732, 0.0321), (0.2338, 0.0706, 0.0320), (0.2572, 0.0679, 0.0317),
    (0.2806, 0.0651, 0.0314), (0.3040, 0.0620, 0.0309), (0.3274, 0.0588, 0.0304), (0.3507, 0.0555, 0.0296),
    (0.3741, 0.0520, 0.0288), (0.3975, 0.0484, 0.0278), (0.4209, 0.0446, 0.0266), (0.4443, 0.0407, 0.0253),
    (0.4676, 0.0368, 0.0239), (0.4910, 0.0327, 0.0224), (0.5144, 0.0286, 0.0207), (0.5378, 0.0245, 0.0189),
    (0.5612, 0.0203, 0.0170), (0.5846, 0.0162, 0.0150), (0.6079, 0.0120, 0.0129), (0.6313, 0.0079, 0.0108),
    (0.6547, 0.0039, 0.0085), (0.6781, 0.0000, 0.0062),
]


def padrao():
    a0 = 5.9                    # inclinacao do perfil (1/rad)
    # ---------------- asa ----------------
    Sw, bw, cw = 1.0, 2.5, 0.40
    ARw = bw ** 2 / Sw
    CLaw = helmbold(a0, ARw)
    iw, CL0w = 2.0, 0.30
    CLw_alfa0 = CL0w + CLaw * math.radians(iw)
    xw, zw = 0.035, -0.12
    # ---------------- EH ----------------
    Sh, ARh = 0.20, 4.0
    ch = math.sqrt(Sh / ARh)
    # ---------------- EV ----------------
    Sv, ARv = 0.12, 1.6
    cv = math.sqrt(Sv / ARv)

    # cada meia asa em dois paineis: interno (sem aileron) e externo (com aileron)
    f_int = 0.6                 # fracao da semi-envergadura do painel interno
    asa = dict(grupo=0, c=cw, AR=ARw, e=0.85, diedro=3.0, incid=iw,
               CLa=CLaw, CL0=CL0w, CLmax=1.6, CD0=0.012, Cmac=-0.08, eta=1.0, x=xw, z=zw)
    y_int, y_ext = f_int * bw / 4, (1 + f_int) * bw / 4
    sup = [
        dict(asa, nome="asa_int_dir", ctrl=0, lado=1, sinal=1, tau=0.0, S=f_int * Sw / 2, y=y_int),
        dict(asa, nome="asa_ext_dir", ctrl=1, lado=1, sinal=-1, tau=0.50, S=(1 - f_int) * Sw / 2, y=y_ext),
        dict(asa, nome="asa_int_esq", ctrl=0, lado=-1, sinal=1, tau=0.0, S=f_int * Sw / 2, y=-y_int),
        dict(asa, nome="asa_ext_esq", ctrl=1, lado=-1, sinal=1, tau=0.50, S=(1 - f_int) * Sw / 2, y=-y_ext),
        dict(nome="EH", grupo=1, ctrl=2, lado=0, sinal=1, x=-1.05, y=0.0, z=-0.05, S=Sh, c=ch, AR=ARh,
             e=0.80, incid=-2.0, CLa=helmbold(a0, ARh), CL0=0.0, CLmax=1.0, CD0=0.012, Cmac=0.0,
             tau=0.50, eta=0.90, downwash=1,
             eps0=math.degrees(2 * CLw_alfa0 / (math.pi * ARw)), depsda=2 * CLaw / (math.pi * ARw)),
        dict(nome="EV", grupo=2, ctrl=3, vertical=1, lado=0, sinal=-1, x=-1.10, y=0.0, z=-0.22,
             S=Sv, c=cv, AR=ARv, e=0.80, incid=0.0, CLa=helmbold(a0, ARv), CL0=0.0, CLmax=1.0,
             CD0=0.012, Cmac=0.0, tau=0.50, eta=0.90),
    ]
    return dict(
        escalares=dict(
            # aeronave seca (sem liquido e sem carga LAPES): massa, inercia no CG dela e posicao desse CG (r_seca)
            m_seca=8.39, Ixx=0.90, Iyy=1.20, Izz=1.90, Ixz=0.04, r_seca=(0.0, 0.0, 0.0),
            Sref=Sw, cref=cw, bref=bw, Mst=50.0,
            fus_CDS=0.030, fus_Cma=0.10, fus_Cnb=-0.03, fus_CYb=-0.15, fus_r=(0.0, 0.0, 0.0),
            # helice e motor: APC 15x8E + Scorpion A-5025-310Kv + 6S
            D=0.381, Ip=5.4e-4, Jm=1.0e-4, phiT=3.0, psiT=0.0, rp=(0.55, 0.0, 0.0), sentido=1.0,
            Kv=310.0, Rm=0.0174 + 0.003, B=32.4e-6, tauc=0.0155, Imax=80.0, Voc=22.2, Rint=0.035,
            # solo
            mu_r=0.04, mu_lat=0.6, mu_freio=1.0, mu_cauda=0.35, mu_pouso=0.40,
            # tanque com liquido (sloshing)
            rt=(0.10, 0.0, 0.05), Rtq=0.08, htq=0.08, rho_liq=1000.0, zeta_s=0.03, slosh=1,
            # carga LAPES
            mL=2.0, rL=(-0.05, 0.0, 0.08), baia=0.35, Fext_g=2.0, mu_b=0.3, CdS_par=0.45,
            # ambiente
            rho=1.225, Vw10=4.0, psiw=30.0, chiw=3.0, hw_ref=10.0, Tg=1.0, Ug=(-1.0, -2.0, -1.0), rajada=0,
            # decolagem (Riboldi et al., 2022): profundor puxa em VR (m/s) ou, se sR > 0, em n = sR (m)
            VR=12.5, sR=0.0, de0=0.0, de1=-6.0, taxa_de=60.0, ht=2.0, taxa_acel=2.0, h_fim_dec=6.0,
            # piloto automatico
            ap_CL0=0.45, ap_CLa=4.5, alfa_max=11.0, g_sobe=0.08, g_desce=0.10, Khr=0.5, Kvs=0.5,
            Kn_h=0.065, Kn_hd=0.13, Kn_ih=0.01, Kae=4.0, KIa=4.0, Kfn=1.2, Lorb=50.0, tlead=0.8,
            Kth_h=2.0, Kth_hd=3.0, Kth_ih=0.3, Kthe=1.5, Kqe=0.25, KIth=0.5,
            KV=0.25, KIV=0.08, KHT=0.10, Dtrim=0.55,
            Kchi=0.8, kvf=0.05, chi_inf=60.0, korb=0.5, tau_phi=0.3, pmax_cmd=60.0, phimax=30.0, Kphia=2.0, Kpa=0.10, Kbeta=1.0,
            Ky=0.15, Ki=0.02, Kpsi=1.5, Kr=0.3, Kbeq=0.5,
            hflare=2.5, thflare=1.0, tau_flare=1.0, Kflare=10.0, kCL=0.95,
            dt=1e-3, tmax=400.0, dtlog=0.02, dtsolo=0.002, tsolo=15.0,
        ),
        superficies=sup,
        contatos=[
            dict(tipo=0, x=0.45, y=0.0, z=0.22, k=2000, c=60),      # bequilha
            dict(tipo=1, x=-0.05, y=-0.30, z=0.22, k=4000, c=120),  # principal esquerda
            dict(tipo=1, x=-0.05, y=0.30, z=0.22, k=4000, c=120),   # principal direita
            dict(tipo=2, x=-1.10, y=0.0, z=0.00, k=6000, c=150),    # cauda
        ],
        helice=APC_15x8E,
        restricoes=dict(dmin=0.03, kCL=0.95, qmax=50.0, gmax=20.0),
    )
