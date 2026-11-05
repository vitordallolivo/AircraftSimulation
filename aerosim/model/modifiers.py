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

GROUND_OFF = "off"             # core/src/modifiers/types.zig: Ground (o esquema da ABI traz os nomes)
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
    core: str                  # o nome no núcleo (types.zig: Ground para "solo", Kind para "aditivo")
    reference: str             # de onde vem a fórmula (obra e equação)
    description: str = ""
    params: tuple[ParamInfo, ...] = ()


KINDS: dict[str, KindInfo] = {
    "solo.mccormick": KindInfo(
        "solo.mccormick", "efeito solo: McCormick", "solo", "mccormick",
        "B. W. McCormick, Aerodynamics, Aeronautics, and Flight Mechanics (Wiley); a mesma expressão em "
        "J. D. Anderson, Aircraft Performance and Design (McGraw-Hill)",
        "φ = (16h/b)² / (1 + (16h/b)²) multiplica o arrasto induzido de cada painel horizontal, com h a altura "
        "do painel acima do chão a cada passo"),
    "esteira.disco": KindInfo(
        "esteira.disco", "esteira da hélice: disco atuador", "aditivo", "slipstream_disk",
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
    "interferencia.asas": KindInfo(
        "interferencia.asas", "interferência entre as asas da configuração", "aditivo", "wing_interference",
        "ferraduras de Γ = ½ V c η c_l (Kutta–Joukowski) e Biot–Savart de segmento reto (Katz e Plotkin, "
        "Low-Speed Aerodynamics, 2ª ed., cap. 10; a conferir no PDF), como na linha sustentadora do núcleo "
        "(Phillips e Snyder 2000), numa passada e só entre asas diferentes",
        "nas faixas, cada asa da configuração sente a velocidade induzida pelas outras, quantas houver: a que "
        "está atrás voa no downwash das da frente, e asas uma sobre a outra se induzem. Só age com o voo pelas "
        "faixas e com duas asas ligadas ou mais. Desligado por padrão",
        (ParamInfo("ganho", "ganho da induzida", 1.0, "", "calibração (1 = a teoria)"),)),
    "comando.momento_flape": KindInfo(
        "comando.momento_flape", "momento próprio dos comandos (flape, profundor, elevon)", "aditivo", "flap_moment",
        "teoria do perfil fino com flape: Δc_m,c/4 = −½ sen θ_f (1 − cos θ_f) δ, cos θ_f = 2 c_f/c − 1 (J. D. "
        "Anderson, Fundamentals of Aerodynamics, seção do flape na teoria do perfil fino; a conferir no PDF)",
        "nas faixas, o comando também muda o momento no quarto de corda da faixa, além do C_L. Sem isso o elevon "
        "de uma asa voadora cabra menos do que deveria, porque o braço dele até o CG é curto. θ_f sai do τ da faixa "
        "com o fator k do τ. Só nas faixas. Desligado por padrão",
        (ParamInfo("fator", "fator empírico k do τ", 0.85, "", "o mesmo de flap_effectiveness (0,85)"),)),
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


def ground_method(ac) -> str:
    """o método do efeito solo para o núcleo (o primeiro "solo" ligado; nenhum: desligado)"""
    m = next((m for m in active(ac) if KINDS[m.kind].category == "solo"), None)
    return KINDS[m.kind].core if m is not None else GROUND_OFF


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


# os ajustes de cada tipo, na ordem da struct de ajustes do núcleo (SlipstreamSettings, InterferenceSettings,
# FlapMomentSettings); as chaves que ligam e desligam vão nos flags
SETTINGS = {"esteira.disco": ("ganho_axial", "ganho_giro"), "interferencia.asas": ("ganho",),
            "comando.momento_flape": ("fator",)}


def _flags(m: Modifier) -> list[str]:
    """os bits ligados de `Modifier.flags` (core/src/modifiers/types.zig: Flags), pelo nome"""
    flags = ["enabled"]
    if m.kind != "esteira.disco" or m.value("axial") != 0:
        flags.append("axial")
    if m.kind != "esteira.disco" or m.value("giro") != 0:
        flags.append("swirl")
    return flags


def native(ac, panel_owner: list[str], prop_count: int, max_mods: int = MAX_MODS) -> dict:
    """os campos do núcleo: `ground`, `n_mod`, `mods` (lista de dicionários `Modifier` do Zig).
    `panel_owner[i]`: nome da superfície do painel i (para a máscara de superfícies)"""
    mods = []
    for m in additive(ac)[:max_mods]:
        inf = KINDS[m.kind]
        targets = m.targets
        if m.kind == "interferencia.asas":          # as asas da configuração: cada uma sente as outras
            wings = [w.name for w in ac.wing_group()] if hasattr(ac, "wing_group") else []
            if len(set(wings)) < 2:
                continue                                                     # uma asa só: nada a fazer
            targets = [t for t in wings if not m.targets or t in m.targets]
        mask = [0, 0]
        if targets:
            for i, owner in enumerate(panel_owner):
                if owner in targets and i < 64:
                    mask[i // 32] |= 1 << (i % 32)
            mask = [_i32(v) for v in mask]
            if mask == [0, 0]:
                continue                                                     # nenhum painel: nada a fazer
        pmask = sum(1 << i for i in m.props if 0 <= i < prop_count)
        vals = [m.value(k) for k in SETTINGS.get(m.kind, ())]
        mods.append(dict(kind=inf.core, flags=_flags(m), surf_mask=mask, prop_mask=pmask,
                         params=(vals + [0.0] * 16)[:16]))
    return dict(ground=ground_method(ac), n_mod=len(mods), mods=mods)


def _i32(v: int) -> int:
    return v - (1 << 32) if v >= 1 << 31 else v
