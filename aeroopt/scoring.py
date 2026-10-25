"""Pontuação: um arquivo .toml por regulamento, traduzido para um programa curto que o núcleo executa.

O arquivo declara as entradas (grandezas que o avaliador entrega, em SI), constantes, faixas (degraus, como o fator
de decolagem), termos em ordem e a expressão da nota, mais as condições de voo válido, que viram restrições. As
expressões aceitam números, os nomes já definidos, + − × / ^, e min, max, exp, abs. Nada mais: a conta é feita
pelo núcleo (`core/src/optim/expr.zig`), e aqui só se traduz.

O programa é uma lista de operações de pilha sobre vagas numeradas: as entradas ocupam as primeiras vagas, e cada
constante, faixa, termo, nota e condição ganha a sua, na ordem do arquivo.

    sc = ScoringFile("aeroopt/pontuacao/sae_br_2026_micro.toml")
    sc.quantities()          # ['c_lapes', 'c_liq', 'pv', 'm_bat', 's_to', 'b']
    prog = sc.program()      # ops, args, consts, faixas, vagas de saída
"""
from __future__ import annotations

import ast
import os

import tomllib

from aerosim.interfaces.optim import OPS, IScoring

# códigos das operações (os mesmos de core/src/optim/expr.zig)
CONST, LOAD, STORE, ADD, SUB, MUL, DIV, POW, NEG, MIN, MAX, EXP, ABS, TIER = range(14)
OP_NAMES = ("CONST", "LOAD", "STORE", "ADD", "SUB", "MUL", "DIV", "POW", "NEG", "MIN", "MAX", "EXP", "ABS", "TIER")
# limites do núcleo (expr.zig)
MAX_OPS, MAX_CONSTS, MAX_SLOTS, MAX_TIERS, MAX_TIER_STEPS, MAX_STACK = 256, 64, 64, 8, 8, 16

_BIN = {ast.Add: ADD, ast.Sub: SUB, ast.Mult: MUL, ast.Div: DIV, ast.Pow: POW}
_FUN = {"min": MIN, "max": MAX, "exp": EXP, "abs": ABS}
PONTUACAO = os.path.join(os.path.dirname(__file__), "pontuacao")


class ScoringError(ValueError):
    pass


class _Compiler:
    def __init__(self):
        self.ops: list[int] = []
        self.args: list[int] = []
        self.consts: list[float] = []
        self.slots: list[str] = []
        self.depth = self.max_depth = 0

    def emit(self, op: int, arg: int = 0, push: int = 0):
        self.ops.append(op)
        self.args.append(arg)
        self.depth += push
        self.max_depth = max(self.max_depth, self.depth)

    def slot(self, name: str) -> int:
        if name in self.slots:
            raise ScoringError(f"nome repetido: {name}")
        self.slots.append(name)
        return len(self.slots) - 1

    def const(self, v: float) -> int:
        if v not in self.consts:
            self.consts.append(float(v))
        return self.consts.index(float(v))

    def expr(self, text: str, where: str) -> None:
        try:
            node = ast.parse(str(text).replace("^", "**"), mode="eval").body
        except SyntaxError as e:
            raise ScoringError(f"{where}: expressão inválida ({e.msg}): {text}") from None
        self._node(node, where)

    def _node(self, n, where):
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)) and not isinstance(n.value, bool):
            self.emit(CONST, self.const(n.value), +1)
        elif isinstance(n, ast.Name):
            if n.id not in self.slots:
                raise ScoringError(f"{where}: nome não definido antes: {n.id}")
            self.emit(LOAD, self.slots.index(n.id), +1)
        elif isinstance(n, ast.BinOp) and type(n.op) in _BIN:
            self._node(n.left, where)
            self._node(n.right, where)
            self.emit(_BIN[type(n.op)], 0, -1)
        elif isinstance(n, ast.UnaryOp) and isinstance(n.op, (ast.USub, ast.UAdd)):
            self._node(n.operand, where)
            if isinstance(n.op, ast.USub):
                self.emit(NEG)
        elif isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in _FUN and not n.keywords:
            f, a = _FUN[n.func.id], n.args
            if f in (EXP, ABS):
                if len(a) != 1:
                    raise ScoringError(f"{where}: {n.func.id} recebe um argumento")
                self._node(a[0], where)
                self.emit(f)
            else:
                if len(a) < 2:
                    raise ScoringError(f"{where}: {n.func.id} recebe dois ou mais argumentos")
                self._node(a[0], where)
                for x in a[1:]:
                    self._node(x, where)
                    self.emit(f, 0, -1)
        else:
            raise ScoringError(f"{where}: só números, nomes, + − × / ^, min, max, exp e abs: {ast.unparse(n)}")

    def store(self, name: str) -> int:
        s = self.slot(name)
        self.emit(STORE, s, -1)
        return s


class ScoringFile(IScoring):
    """um arquivo de pontuação (.toml); um nome sem caminho procura em aeroopt/pontuacao"""

    def __init__(self, path: str):
        if not os.path.exists(path) and not os.path.dirname(path):
            path = os.path.join(PONTUACAO, path if path.endswith(".toml") else path + ".toml")
        self.path = path
        with open(path, "rb") as f:
            self.data = tomllib.load(f)
        self.name = self.data.get("nome", os.path.basename(path))
        self.source = self.data.get("fonte", "")
        self._program = self._compile()

    def quantities(self) -> list[str]:
        return list(self.data.get("entradas", []))

    def program(self) -> dict:
        return self._program

    def _compile(self) -> dict:
        d, c = self.data, _Compiler()
        if not d.get("entradas"):
            raise ScoringError("o arquivo não declara as entradas")
        for name in d["entradas"]:
            c.slot(name)
        for name, v in d.get("constantes", {}).items():
            c.emit(CONST, c.const(v), +1)
            c.store(name)
        tiers = []
        for name, t in d.get("faixas", {}).items():
            lim, val = [float(x) for x in t["limites"]], [float(x) for x in t["valores"]]
            if len(lim) != len(val) or not lim or lim != sorted(lim):
                raise ScoringError(f"faixa {name}: limites crescentes e um valor por limite")
            if len(lim) > MAX_TIER_STEPS:
                raise ScoringError(f"faixa {name}: no máximo {MAX_TIER_STEPS} degraus")
            c.expr(t["grandeza"], f"faixa {name}")
            c.emit(TIER, len(tiers))
            tiers.append(dict(limits=lim, values=val, outside=float(t.get("fora", 0.0))))
            c.store(name)
        parts = {}
        for name, text in d.get("termos", {}).items():
            c.expr(text, f"termo {name}")
            parts[name] = c.store(name)
        if "nota" not in d or "expressao" not in d["nota"]:
            raise ScoringError("o arquivo não tem [nota] expressao")
        c.expr(d["nota"]["expressao"], "nota")
        score = c.store("nota")
        valid = []
        for i, v in enumerate(d.get("validade", [])):
            if v.get("op") not in OPS:
                raise ScoringError(f"validade {i + 1}: operador {v.get('op')!r} (use {', '.join(OPS)})")
            c.expr(v["expressao"], f"validade {i + 1}")
            valid.append(dict(slot=c.store(f"validade_{i + 1}"), op=v["op"], value=float(v["valor"]),
                              text=v["expressao"], source=v.get("fonte", "")))
        limits = ((len(c.ops), MAX_OPS, "operações"), (len(c.consts), MAX_CONSTS, "constantes"),
                  (len(c.slots), MAX_SLOTS, "vagas"), (len(tiers), MAX_TIERS, "faixas"),
                  (c.max_depth, MAX_STACK, "profundidade da pilha"))
        for n, mx, what in limits:
            if n > mx:
                raise ScoringError(f"{what}: {n} (o núcleo aceita até {mx})")
        return dict(ops=c.ops, args=c.args, consts=c.consts, slots=c.slots, n_inputs=len(d["entradas"]),
                    tiers=tiers, score=score, parts=parts, valid=valid)


class Objective(IScoring):
    """objetivo simples: maximizar uma grandeza (MTOW, EE...)"""

    def __init__(self, quantity: str):
        self.q = quantity
        self.name, self.source = f"maximizar {quantity}", ""

    def quantities(self) -> list[str]:
        return [self.q]

    def program(self) -> dict:
        return dict(ops=[LOAD, STORE], args=[0, 1], consts=[], slots=[self.q, "nota"], n_inputs=1, tiers=[],
                    score=1, parts={}, valid=[])


def scoring_for(spec: str) -> IScoring:
    """'MTOW', 'EE' → objetivo simples; um .toml (caminho ou nome em aeroopt/pontuacao) → ScoringFile"""
    if spec.endswith(".toml") or os.path.exists(os.path.join(PONTUACAO, spec + ".toml")):
        return ScoringFile(spec)
    return Objective(spec.lower() if spec in ("MTOW", "EE") else spec)


def evaluate(scoring: IScoring, rows, backend=None) -> list[dict]:
    """a nota de cada candidato, calculada no núcleo. `rows`: dicionários com as entradas (ou um só).
    Devolve, por candidato: nota, termos (os fatores), validade [(texto, cumpre, valor)] e válido"""
    if backend is None:
        from aerosim.backend.zig import ZigBackend
        backend = ZigBackend()
    rows = [rows] if isinstance(rows, dict) else list(rows)
    prog, names = scoring.program(), scoring.quantities()
    missing = sorted({n for r in rows for n in names if n not in r})
    if missing:
        raise KeyError(f"faltam entradas: {', '.join(missing)}")
    out = backend.expr_eval(prog, [[float(r[n]) for n in names] for r in rows])
    res = []
    for v in out:
        checks = []
        for c in prog["valid"]:
            x = float(v[c["slot"]])
            ok = x <= c["value"] if c["op"] == "≤" else x >= c["value"] if c["op"] == "≥" else \
                abs(x - c["value"]) <= 1e-9
            checks.append((f"{c['text']} {c['op']} {c['value']:g}", bool(ok), x))
        res.append(dict(nota=float(v[prog["score"]]), termos={k: float(v[i]) for k, i in prog["parts"].items()},
                        validade=checks, valido=all(ok for _, ok, _ in checks)))
    return res


def listing(prog: dict) -> str:
    """o programa em texto, uma operação por linha (para ler e conferir)"""
    out = []
    for op, a in zip(prog["ops"], prog["args"]):
        if op == CONST:
            out.append(f"CONST {prog['consts'][a]:g}")
        elif op in (LOAD, STORE):
            out.append(f"{OP_NAMES[op]} {prog['slots'][a]}")
        elif op == TIER:
            out.append(f"TIER {a}")
        else:
            out.append(OP_NAMES[op])
    return "\n".join(out)
