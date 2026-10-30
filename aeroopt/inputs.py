"""Tudo o que o usuário escolhe nas etapas do aerosim e que pode variar: o catálogo das variáveis do aeroopt.

Cada campo dos rascunhos da sprint (asa, empenagem, motores, requisitos, regras e massas) já diz, na definição
(`aerosim.design.fields.F`), o nome, a unidade e a faixa em que faz sentido, ou as escolhas que tem. Daqui sai uma
variável para cada um: o número com faixa vira variável contínua (ou inteira, com o passo do campo), a escolha vira
lista (a cauda, o trem, o arranjo dos motores), o sim/não vira lista de duas opções, e o perfil, o motor, a hélice e a
bateria viram listas do que existe (os perfis do projeto e da pasta, o catálogo). Assim um campo novo numa etapa do
aerosim aparece sozinho no aeroopt. As chaves do registro da sprint (`design.registry.INPUTS`) continuam valendo
com o mesmo nome (`wing.span`, `power.motors`...); as outras são `<grupo>.<campo>`.

    for k, i in all_inputs().items():
        print(k, i.label, i.kind, i.lo, i.hi)
"""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass
from functools import lru_cache

# (prefixo da chave, atributo do projeto, grupo)
DRAFTS = (("wing", "wing_draft", "asa"), ("tail", "tail_draft", "empenagem"), ("power", "power_draft", "motores, carga e trem"),
          ("req", "requirements", "requisitos"), ("rules", "rules", "regras e massas"))
GROUP_ORDER = tuple(g for _, _, g in DRAFTS)
# campos que não são escolha de projeto: nomes, ligações entre candidatos, tabelas e o modo de preencher
SKIP = {"name", "config", "wing", "wing2", "set", "thrust_set", "partitions", "constraints", "planform", "size_by",
        "thrust_model"}
# campos de texto que são escolhas do que existe (as listas puxadas do projeto e do catálogo)
CATALOG = {"airfoil": "perfis", "airfoil_tip": "perfis", "tail_airfoil": "perfis", "vtail_airfoil": "perfis",
           "wing2_airfoil": "perfis", "motor": "motores", "propeller": "hélices", "battery": "baterias"}
# os nomes de sempre (o registro da sprint e as primeiras listas do aeroopt) para os mesmos campos
ALIAS = {"tail_draft.tail_airfoil": "tail.airfoil", "tail_draft.vtail_airfoil": "tail.vairfoil",
         "power_draft.battery": "power.battery"}
YES, NO = "sim", "não"


@dataclass(frozen=True)
class Input:
    key: str
    path: str                     # "<atributo do projeto>.<campo>"
    label: str
    unit: str = ""
    kind: str = "contínua"        # contínua, inteira, lista
    lo: float = 0.0
    hi: float = 1.0
    step: float = 0.0
    group: str = ""
    source: str = ""              # lista: perfis, motores, hélices, baterias, escolhas, sim/não
    choices: tuple = ()


def _registry() -> dict[str, Input]:
    from aerosim.design import registry as rg
    out = {}
    for k, i in rg.INPUTS.items():
        obj, _, attr = i.path.partition(".")
        grp = next((g for p, o, g in DRAFTS if o == obj), "")
        if i.unit == "lista":
            out[k] = Input(k, i.path, i.label, "", "lista", group=grp,
                           source=CATALOG.get(attr, "escolhas"))
        else:
            out[k] = Input(k, i.path, i.label, i.unit, "inteira" if i.integer else "contínua", float(i.lo),
                           float(i.hi), group=grp)
    return out


@lru_cache(maxsize=1)
def _all() -> tuple[tuple[str, Input], ...]:
    from aerosim.design.project import DesignProject
    proj = DesignProject()
    reg = _registry()
    by_path = {i.path: k for k, i in reg.items()}
    out = dict(reg)
    for prefix, obj, grp in DRAFTS:
        draft = getattr(proj, obj)
        for f in dataclasses.fields(draft):
            if f.name in SKIP or "label" not in f.metadata:
                continue
            path = f"{obj}.{f.name}"
            m = f.metadata
            key = by_path.get(path) or ALIAS.get(path) or f"{prefix}.{f.name}"
            if key in reg:
                old = reg[key]                    # o registro manda nas faixas; o campo dá o passo
                step = (m.get("range") or (None, None, None))[2] or 0.0
                out[key] = dataclasses.replace(old, step=float(step), choices=tuple(m.get("choices", ())))
                if old.kind == "lista" and m.get("choices"):
                    out[key] = dataclasses.replace(out[key], source="escolhas")
                continue
            val = getattr(draft, f.name)
            label, unit = m["label"], m.get("unit", "")
            if f.name in CATALOG:
                out[key] = Input(key, path, label, "", "lista", group=grp, source=CATALOG[f.name])
            elif m.get("choices"):
                out[key] = Input(key, path, label, "", "lista", group=grp, source="escolhas",
                                 choices=tuple(m["choices"]))
            elif isinstance(val, bool):
                out[key] = Input(key, path, label, "", "lista", group=grp, source="sim/não", choices=(YES, NO))
            elif isinstance(val, (int, float)) and m.get("range"):
                lo, hi, step = m["range"]
                out[key] = Input(key, path, label, unit, "inteira" if isinstance(val, int) else "contínua",
                                 float(lo), float(hi), float(step or 0.0), grp)
    order = {g: n for n, g in enumerate(GROUP_ORDER)}
    return tuple(sorted(out.items(), key=lambda kv: order.get(kv[1].group, 99)))


def all_inputs() -> dict[str, Input]:
    """todas as variáveis possíveis, na ordem dos grupos (asa, empenagem, motores, requisitos, regras)"""
    return dict(_all())


def get(key: str) -> Input | None:
    return all_inputs().get(key)


def _split(path: str) -> tuple[str, str]:
    obj, _, attr = path.partition(".")
    return obj, attr


def get_value(project, key: str):
    i = get(key)
    if i is None:
        raise KeyError(f"variável desconhecida: {key}")
    obj, attr = _split(i.path)
    v = getattr(getattr(project, obj), attr)
    if i.source == "sim/não":
        return YES if v else NO
    return v


def set_value(project, key: str, value) -> None:
    i = get(key)
    if i is None:
        raise KeyError(f"variável desconhecida: {key}")
    obj, attr = _split(i.path)
    target = getattr(project, obj)
    old = getattr(target, attr)
    if i.source == "sim/não":
        value = value in (True, YES, "True", "true", 1)
    elif i.kind == "inteira":
        value = int(round(float(value)))
    elif i.kind == "contínua":
        value = float(value)
    elif isinstance(old, str):
        value = str(value)
    setattr(target, attr, value)


def integer_values(i: Input, lo: float, hi: float) -> list[int]:
    """os valores de uma variável inteira entre os limites, no passo do campo (os motores na asa vão aos pares)"""
    a, b = round(min(lo, hi)), round(max(lo, hi))
    step = max(int(round(i.step)) if i and i.step else 1, 1)
    first = a + (-a % step)                       # no passo a partir do zero: 2, 4, 6...
    return list(range(first, b + 1, step)) or [a]
