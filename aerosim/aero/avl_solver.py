"""AVL (Drela e Youngren, MIT; GPL): malha de vórtices em ferradura com superfícies de comando.

O programa é externo: precisa do executável `avl` no PATH (ou na variável AVL_PATH). Sem ele o método
aparece como indisponível, com o motivo.

`AvlTranslator`:
  ida   — cada superfície do modelo universal vira um SURFACE do .avl com as mesmas estações (SECTION:
          bordo de ataque, corda, incidência + torção), em eixos x para trás, y à direita, z para cima
          (x' = −x, z' = −z); espelhada = YDUPLICATE 0. Perfil: NACA de 4 dígitos pelo código, os outros
          pelo contorno (AFILE); só parâmetros = placa plana. Comandos: três variáveis do AVL, `pitch`,
          `roll` e `yaw`, com os ganhos da mistura de cada faixa (rolagem antissimétrica no espelho).
          C_D0 do modelo entra como CDp (o mesmo que o núcleo soma)
  roda  — uma sessão do AVL por varredura: para cada ponto, A/B/R/P/Y e D1..D3 fixados, X e ST num arquivo
  volta — o AVL dá C_l e C_n por S b nos eixos dele: C_l = −C_l', C_n = −C_n'; C_m, C_L, C_D, C_Y iguais;
          C_D inclui o CDp, C_Di = CDind
As taxas entram como p' = −p, q' = q, r' = −r (eixos do AVL). Conferido o formato; os sinais de δa e δr
seguem o AVL (positivo = bordo de fuga para baixo do lado direito).
"""
from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
import tempfile

import numpy as np

from aerosim.interfaces.aero import AeroCase, FlightPoint
from aerosim.interfaces.translator import IModelTranslator

from .base import AeroSolverBase
from .geometry import to_xz_up

CONTROLS = ("pitch", "roll", "yaw")          # D1, D2, D3 no AVL
SGN_DUP = {"pitch": 1.0, "roll": -1.0, "yaw": 1.0}
TIMEOUT = 120.0


def avl_exe() -> str | None:
    p = os.environ.get("AVL_PATH")
    if p and os.path.exists(p):
        return p
    return shutil.which("avl")


def _naca_code(name: str) -> str | None:
    d = "".join(ch for ch in name if ch.isdigit())
    return d if "naca" in name.lower() and len(d) == 4 else None


def _fmt(*v) -> str:
    return " ".join(f"{float(x):.6g}" for x in v)


class AvlTranslator(IModelTranslator):
    name = "avl"

    def to_native(self, model, case: AeroCase = None, folder: str = "", **_) -> str:
        """modelo universal -> texto do .avl (os contornos que não são NACA vão para `folder`)"""
        case = case or AeroCase()
        ref = to_xz_up(case.ref)
        L = [model.name or "aerosim", "0.0", "0 0 0.0", _fmt(model.S, model.c, model.b), _fmt(*ref),
             _fmt(model.parasite_cd()), ""]
        written: dict[str, str] = {}
        for i, s in enumerate(model.surfaces):
            L += ["SURFACE", s.name or f"superficie {i}", f"8 1.0 {max(4, int(case.n_span))} {-2.0 if s.mirror else 1.0}"]
            if s.mirror:
                L += ["YDUPLICATE", "0.0"]
            ctl = s.strip_controls
            for k, q in enumerate(s.stations):
                le = to_xz_up(q.le)
                L += ["SECTION", _fmt(*le, q.chord, 0.0 if s.vertical else q.twist)]
                af = q.airfoil or s.airfoil
                code = _naca_code(af.name)
                if code:
                    L += ["NACA", code]
                elif af.coords or (af.path and os.path.exists(af.path)):
                    fn = written.get(af.name)
                    if fn is None:
                        fn = written[af.name] = f"af{len(written)}.dat"
                        if folder:
                            c = af.outline()
                            with open(os.path.join(folder, fn), "w") as f:
                                f.write(af.name + "\n" + "\n".join(f"{x:.6f} {y:.6f}" for x, y in c) + "\n")
                    L += ["AFILE", fn]
                # o comando da faixa de dentro ou de fora desta estação (o AVL liga seção a seção)
                near = [c for c in (ctl[k - 1] if k > 0 else None, ctl[k] if k < len(ctl) else None) if c is not None]
                if near:
                    c = near[0]
                    for name, g in zip(CONTROLS, c.gains):
                        if g:
                            L += ["CONTROL", f"{name} {g:.6g} {1.0 - c.chord_frac:.4f} 0 0 0 {SGN_DUP[name]:g}"]
            L.append("")
        return "\n".join(L) + "\n"

    @staticmethod
    def commands(model, points: list[FlightPoint], avl_file: str, out: str) -> str:
        """entrada do AVL para a varredura: um ST por ponto (out0.st, out1.st...)"""
        c = [f"LOAD {avl_file}", "OPER"]
        for i, pt in enumerate(points):
            c += [f"A A {math.degrees(pt.alpha):.6f}", f"B B {math.degrees(pt.beta):.6f}",
                  f"R R {-pt.p:.6f}", f"P P {pt.q:.6f}", f"Y Y {-pt.r:.6f}",
                  f"D1 D1 {math.degrees(pt.de):.6f}", f"D2 D2 {math.degrees(pt.da):.6f}",
                  f"D3 D3 {math.degrees(pt.dr):.6f}", "X", f"ST {out}{i}.st"]
        return "\n".join(c + ["", "QUIT", ""])

    def from_native(self, text: str, model, **_) -> dict[str, float]:
        """texto do ST -> coeficientes universais"""
        def g(k):
            m = re.search(rf"\b{re.escape(k)}\s*=\s*([-+0-9.eE]+)", text)
            return float(m.group(1)) if m else np.nan
        return dict(CL=g("CLtot"), CD=g("CDtot"), CDi=g("CDind"), CY=g("CYtot"), Cm=g("Cmtot"),
                    Cl=-g("Cltot"), Cn=-g("Cntot"))


class AvlSolver(AeroSolverBase):
    name = "avl"
    title = "AVL (malha de vórtices)"
    description = "malha de vórtices do Drela com superfícies de comando; programa externo"
    level = "detalhado"
    fidelity, cost = "vlm", "caro"
    supports_controls = True
    notes = "AVL: superfícies do modelo (sem fuselagem); C_D = induzido + C_D0 do modelo (CDp)"
    translator = AvlTranslator()

    def available(self):
        return None if avl_exe() else "AVL não encontrado (ponha o executável 'avl' no PATH ou em AVL_PATH)"

    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]):
        exe = avl_exe()
        if exe is None:
            raise RuntimeError(self.available())
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "aviao.avl"), "w") as f:
                f.write(self.translator.to_native(model, case=case, folder=d))
            r = subprocess.run([exe], input=self.translator.commands(model, points, "aviao.avl", "st"), cwd=d,
                               capture_output=True, text=True, timeout=TIMEOUT)
            out = []
            for i in range(len(points)):
                p = os.path.join(d, f"st{i}.st")
                if not os.path.exists(p):
                    raise RuntimeError(f"o AVL não escreveu o ponto {i}: {r.stdout[-300:]}")
                with open(p) as f:
                    out.append(self.translator.from_native(f.read(), model))
        return out
