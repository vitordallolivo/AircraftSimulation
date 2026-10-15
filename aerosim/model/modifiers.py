"""Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro (efeito solo, esteira
da hélice, tabelas de correção vindas de VSPAERO/CFD/túnel...).

Aqui só há DADOS: o avião guarda a lista `Aircraft.modifiers`; o tradutor do núcleo (`backend/zig/translator.py`)
leva para os campos `ground`, `n_mod` e `mods` dos parâmetros, e quem calcula é o módulo Zig
`core/src/modifiers/` (documentado no README.md de lá, com as referências de cada fórmula).

Dois tipos de modificador:
    categoria "solo"     método de um efeito que sempre existe; um por vez. Sem nenhum na lista: desligado.
    categoria "aditivo"  efeito a mais, somado em cada painel; desligado enquanto não estiver na lista.

Arquivos antigos (sem `modifiers`) abrem com `default_modifiers()` = [solo.mccormick], que é exatamente o que o
núcleo sempre fez. O .cfg e a planilha não guardam modificadores (`not_exported` diz o que se perde).

    ac.modifiers                                  # [Modifier(kind="solo.mccormick")]
    ac.modifiers = []                             # sem efeito solo
    describe(ac)                                  # ["efeito solo: McCormick (padrão)"]
"""
from __future__ import annotations

from dataclasses import dataclass, field

GROUND_OFF = 0                 # core/src/modifiers/types.zig: ground_off
MAX_MODS = 8                   # core/src/limits.zig: max_mods (conferido contra o esquema nos testes)


@dataclass(frozen=True)
class ParamInfo:
    key: str
    label: str
    default: float
    unit: str = ""
    help: str = ""


@dataclass(frozen=True)
class KindInfo:
    kind: str
    title: str
    category: str              # "solo" | "aditivo"
    core_id: int               # o número do tipo no núcleo (types.zig)
    reference: str             # de onde vem a fórmula (obra e equação)
    description: str = ""
    params: tuple[ParamInfo, ...] = ()


KINDS: dict[str, KindInfo] = {
    "solo.mccormick": KindInfo(
        "solo.mccormick", "efeito solo: McCormick", "solo", 1,
        "B. W. McCormick, Aerodynamics, Aeronautics, and Flight Mechanics (Wiley); a mesma expressão em "
        "J. D. Anderson, Aircraft Performance and Design (McGraw-Hill)",
        "φ = (16h/b)² / (1 + (16h/b)²) multiplica o arrasto induzido de cada painel horizontal, com h a altura "
        "do painel acima do chão a cada passo"),
    "esteira.disco": KindInfo(
        "esteira.disco", "esteira da hélice: disco atuador", "aditivo", 1,
        "teoria do momento de Rankine–Froude (McCormick; Glauert em Durand, Aerodynamic Theory IV, 1935); "
        "w(x) = w0 (1 + x/√(x² + R²)) do disco atuador (McCormick, Aerodynamics of V/STOL Flight; Veldhuis, "
        "ICAS 2004 / tese TU Delft 2005); giro pelo balanço de momento angular (Glauert)",
        "cada motor sopra um tubo atrás do disco: velocidade axial a mais (pela tração do instante) e giro no "
        "sentido da hélice (pelo torque). As faixas da asa e da cauda dentro do tubo veem mais pressão dinâmica e "
        "outro α. Desligado por padrão; N motores se somam",
        (ParamInfo("axial", "velocidade axial", 1.0, "", "1 liga, 0 desliga"),
         ParamInfo("giro", "giro da esteira", 1.0, "", "1 liga, 0 desliga"),
         ParamInfo("ganho_axial", "ganho da axial", 1.0, "", "calibração (1 = a teoria)"),
         ParamInfo("ganho_giro", "ganho do giro", 1.0, "", "calibração (1 = a teoria)"))),
}


@dataclass
class Modifier:
    kind: str = "solo.mccormick"
    enabled: bool = True
    name: str = ""                                          # rótulo livre
    params: dict = field(default_factory=dict)              # chave de ParamInfo -> valor (falta = padrão)
    targets: list[str] = field(default_factory=list)        # superfícies afetadas (nome); vazio = todas
    props: list[int] = field(default_factory=list)          # motores envolvidos (índice); vazio = todos

    @property
    def info(self) -> KindInfo | None:
        return KINDS.get(self.kind)

    def value(self, key: str) -> float:
        inf = self.info
        p = next((q for q in (inf.params if inf else ()) if q.key == key), None)
        return float(self.params.get(key, p.default if p else 0.0))


def default_modifiers() -> list[Modifier]:
    """o que o núcleo sempre fez: efeito solo de McCormick"""
    return [Modifier("solo.mccormick")]


def active(ac) -> list[Modifier]:
    return [m for m in getattr(ac, "modifiers", []) if m.enabled and m.kind in KINDS]


def ground_method(ac) -> int:
    """o método do efeito solo para o núcleo (o primeiro "solo" ligado; nenhum: desligado)"""
    m = next((m for m in active(ac) if KINDS[m.kind].category == "solo"), None)
    return KINDS[m.kind].core_id if m is not None else GROUND_OFF


def additive(ac) -> list[Modifier]:
    return [m for m in active(ac) if KINDS[m.kind].category == "aditivo"]


def problems(ac) -> list[str]:
    """o que está errado na lista (tipo desconhecido, dois métodos de solo, aditivos demais)"""
    out = []
    mods = getattr(ac, "modifiers", [])
    for m in mods:
        if m.kind not in KINDS:
            out.append(f"modificador desconhecido '{m.kind}' (de outra versão?): ignorado")
    solos = [m for m in active(ac) if KINDS[m.kind].category == "solo"]
    if len(solos) > 1:
        out.append(f"{len(solos)} métodos de efeito solo ligados: vale só o primeiro ({solos[0].kind})")
    return out


def describe(ac) -> list[str]:
    """uma linha por modificador ligado (para o resumo das análises)"""
    out = []
    for m in active(ac):
        t = KINDS[m.kind].title
        out.append(t + (" (padrão)" if m.kind == "solo.mccormick" else "") + (f" — {m.name}" if m.name else ""))
    if not any(KINDS[m.kind].category == "solo" for m in active(ac)):
        out.append("efeito solo: desligado")
    return out


def is_default(ac) -> bool:
    mods = getattr(ac, "modifiers", [])
    return [(m.kind, m.enabled, m.params, m.targets, m.props) for m in mods] == \
        [(m.kind, m.enabled, m.params, m.targets, m.props) for m in default_modifiers()]


def not_exported(ac, path: str) -> list[str]:
    """o que se perde ao gravar em `path` (.cfg e planilha não guardam modificadores)"""
    if path.lower().endswith(".json") or is_default(ac):
        return []
    return [f"os modificadores ({', '.join(m.kind for m in getattr(ac, 'modifiers', []))}) não cabem neste "
            "formato: ao abrir de novo volta o padrão (efeito solo de McCormick). Grave em .json para guardar."]


def native(ac, panel_owner: list[str], prop_count: int, max_mods: int = MAX_MODS) -> dict:
    """os campos do núcleo: `ground`, `n_mod`, `mods` (lista de dicionários `Modifier` do Zig).
    `panel_owner[i]`: nome da superfície do painel i (para a máscara de superfícies)"""
    mods = []
    for m in additive(ac)[:max_mods]:
        inf = KINDS[m.kind]
        mask = [0, 0]
        if m.targets:
            for i, owner in enumerate(panel_owner):
                if owner in m.targets:
                    mask[i // 32] |= 1 << (i % 32)
            mask = [v - (1 << 32) if v >= 1 << 31 else v for v in mask]      # i32 com sinal
            if mask == [0, 0]:
                continue                                                     # nenhum painel: nada a fazer
        pmask = sum(1 << i for i in m.props if 0 <= i < prop_count)
        vals = [m.value(p.key) for p in inf.params] + [0.0] * (16 - len(inf.params))
        mods.append(dict(kind=inf.core_id, enabled=1, surf_mask=mask, prop_mask=pmask, params=vals[:16]))
    return dict(ground=ground_method(ac), n_mod=len(mods), mods=mods)
