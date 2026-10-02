"""Envelope_main original transcrito (mesmas fórmulas e laço), só sem gráfico e sem input(),
para comparar com o núcleo no modo "reproduzir o original". Recebe o data_dict do AircraftData()."""
import numpy as np


def envelope_main(data_dict, velstep=0.0005, tol=0.00001, Vi=4, Vf=30, d_altitude=50, h_max=20000):
    rho0 = data_dict['Controle']['rho0']
    m = data_dict['Controle']['m']
    g = data_dict['Controle']['g']
    alpha = data_dict["Controle"]['AnguloCruzeiro']
    Fator_de_carga = data_dict['Controle']['n']
    A = data_dict['Arrastos']
    Sw, Clalphaw, Cl0w, Clmaxw = A['Sw'], A['Claw'], A['Cl0w'], A['CLmax']
    CDpw_c1, CDpw_c2, iw = A['Cdpw_c1'], A['Cdpw_c2'], A['iw']
    depsilondalpha, epsilon0, K = A['depsilondalpha'], A['epsilon0'], A['K']
    Sh, Clalphah, CL0h, Clmaxh = A['Sh'], A['Clah'], A['Cl0h'], A['CLmaxh']
    CDph_c1, CDph_c2, ih = A['Cdph_c1'], A['Cdph_c2'], A['ih']
    alphah = alpha * (1 - depsilondalpha) - epsilon0 + ih
    Tc = data_dict["Tracao"]
    n, T0 = Tc["n"], Tc["T0"]
    p = {k: Tc[k] for k in Tc if k.startswith("p")}

    altitude = np.array([0])
    teto, k = 0, 0
    Ve, vcru, vmin, vmax = (np.array([]) for _ in range(4))
    lambda_, R = 0.0065, 287.053
    constant = (-g / (lambda_ * R) - 1)
    w = m * g
    while teto == 0 and altitude[-1] <= h_max:
        rho = rho0 * (1 + (lambda_ * altitude[k]) / 288.15) ** constant
        v = np.arange(Vi, Vf + velstep, velstep)
        Td = g * (rho / rho0) * (T0 + p["p10"] * n + p["p01"] * v + p["p20"] * n**2 + p["p11"] * n * v
                                 + p["p02"] * v**2 + p["p30"] * n**3 + p["p21"] * n**2 * v + p["p12"] * n * v**2
                                 + p["p03"] * v**3 + p["p40"] * n**4 + p["p31"] * n**3 * v + p["p22"] * n**2 * v**2
                                 + p["p13"] * n * v**3 + p["p04"] * v**4 + p["p50"] * n**5 + p["p41"] * n**4 * v
                                 + p["p32"] * n**3 * v**2 + p["p23"] * n**2 * v**3 + p["p14"] * n * v**4
                                 + p["p05"] * v**5)
        CDpw = CDpw_c1 * 12 + CDpw_c2
        CDph = CDph_c1 * 12 + CDph_c2
        Cl = (m * g - Td * np.sin(alpha)) / (0.5 * Sw * rho * v**2)
        Cd = (CDpw + (CDph * (Sh / Sw))) + K * (Cl**2)
        Tr = (rho / rho0) * (v**2) * (Sw * Cd) / (2 * np.cos(alpha))
        Pd, Pr = Td * v, Tr * v
        intersections = np.argwhere(np.diff(np.sign(Pd - Pr))).flatten()
        if len(intersections) == 0:
            break
        vmin = np.append(vmin, v[intersections[0]])
        vmax = np.append(vmax, v[intersections[1]])
        if abs(vmax[k] - vmin[k]) < tol:
            teto = 1
        altitude = np.append(altitude, altitude[-1] + d_altitude)
        Ve = np.append(Ve, np.sqrt((2 * m * g) / (rho * (Sw * Clmaxw + Sh * Clmaxh))))
        CLw = Cl0w + Clalphaw * (iw + alpha)
        CLh = -CL0h + Clalphah * alphah
        vcru = np.append(vcru, np.sqrt(abs((2 * (m * g - Td[-1] * np.sin(alpha))) / (rho * (Sw * CLw + Sh * CLh)))))
        k += 1
    V_manobra = Ve * np.sqrt(Fator_de_carga)
    return dict(h=altitude[:len(vmin)], Vmin=vmin, Vmax=vmax, Ve=Ve, Vman=V_manobra, Vcru=vcru)


def data_dict_from_fixture():
    """o que o AircraftData() devolveria para a planilha de teste (mesmas conversões)"""
    import math
    from sheet_fixtures import GERAL as G, SETS, SUPERFICIES as S
    name, T0, n, p10, p01, p02 = SETS[G["C28"] - 1]
    p = {t: 0.0 for t in ["p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03", "p40", "p31", "p22",
                          "p13", "p04", "p50", "p41", "p32", "p23", "p14", "p05"]}
    p.update(p10=p10, p01=p01, p02=p02)
    return {
        "Controle": dict(rho0=G["C18"], m=G["C8"], g=9.80665, AnguloCruzeiro=G["C14"] * math.pi / 180, n=G["C13"],
                         nhelice=G["C28"]),
        "Arrastos": dict(Sw=S["C3"], Claw=S["C4"] * 180 / math.pi, Cl0w=S["C5"], CLmax=S["C13"],
                         Cdpw_c1=S["G36"], Cdpw_c2=S["G37"], iw=S["C9"] * math.pi / 180, depsilondalpha=S["C10"],
                         epsilon0=S["C11"] * math.pi / 180, K=S["C17"], Sh=S["G3"], Clah=S["G4"] * 180 / math.pi,
                         Cl0h=S["G5"], CLmaxh=S["G11"], Cdph_c1=S["J36"], Cdph_c2=S["J37"],
                         ih=S["G9"] * math.pi / 180),
        "Tracao": dict(n=n, T0=T0, **p),
    }
