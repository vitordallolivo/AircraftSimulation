"""Grafo do código: lê o Zig e o Python do repositório e devolve quem é quem e quem chama quem, sem lista feita à mão.

    python tools/grafo.py                       # grava zig-out/site/grafo.json (o tools/livro.py chama sozinho)
    python tools/grafo.py --resumo              # só imprime quantos módulos, funções e ligações achou

Cada arquivo vira um módulo (no Zig o arquivo já é uma struct); dentro dele ficam as structs, enums e classes, e as
funções e métodos com a assinatura, o `///` ou a docstring e as linhas onde estão. As chamadas saem do corpo de cada
função: no Python pela árvore do `ast`; no Zig por leitura do texto, seguindo os `@import` e os apelidos
(`const runner = core.runner`). Uma chamada que não dá para resolver sem ambiguidade (um `x.step()` com dois `step`
possíveis) fica de fora, em vez de virar uma ligação errada.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDERS = ("core/src", "aerosim", "aeroopt", "aerodrive/src", "tools")
SKIPPED_DIRS = {"zig-pkg", ".zig-cache", "zig-cache", "zig-out", "__pycache__", "tests", "node_modules"}
OUT = os.path.join(ROOT, "zig-out", "site", "grafo.json")


def is_test(name: str) -> bool:
    return name in ("tests.zig", "build.zig", "conftest.py") or name.startswith("test_") or name.endswith("_test.zig")


def source_files() -> list[str]:
    found = []
    for folder in FOLDERS:
        for base, dirs, files in os.walk(os.path.join(ROOT, folder)):
            dirs[:] = sorted(d for d in dirs if d not in SKIPPED_DIRS and not d.startswith("."))
            for name in sorted(files):
                if name.endswith((".zig", ".py")) and not is_test(name):
                    found.append(os.path.relpath(os.path.join(base, name), ROOT).replace(os.sep, "/"))
    return found


def module_name(path: str) -> str:
    """`core/src/sim/runner.zig` → `core.sim.runner`: o nome do módulo, sem pasta nem extensão."""
    stem = path.rsplit(".", 1)[0].replace("core/src/", "core/").replace("aerodrive/src/", "aerodrive/")
    if stem.endswith("/__init__"):
        stem = stem[: -len("/__init__")]
    return stem.replace("/", ".")


def group_of(path: str) -> str:
    parts = module_name(path).split(".")
    return ".".join(parts[:2]) if len(parts) > 2 else parts[0]


class Graph:
    """Os módulos, os símbolos (structs, classes, funções) e as ligações de chamada."""

    def __init__(self):
        self.modules: dict[str, dict] = {}
        self.symbols: dict[str, dict] = {}
        self.calls: set[tuple[str, str]] = set()
        self.sources: dict[str, str] = {}

    def add_module(self, path: str, text: str, lang: str):
        self.sources[path] = text
        self.modules[path] = {"id": path, "nome": module_name(path), "grupo": group_of(path), "lang": lang,
                              "linhas": text.count("\n") + 1, "simbolos": []}

    def add_symbol(self, path: str, symbol_id: str, **fields):
        self.symbols[symbol_id] = {"id": symbol_id, "modulo": path, **fields}
        self.modules[path]["simbolos"].append(symbol_id)

    def to_json(self) -> dict:
        callers: dict[str, list[str]] = {}
        callees: dict[str, list[str]] = {}
        for source, target in sorted(self.calls):
            callees.setdefault(source, []).append(target)
            callers.setdefault(target, []).append(source)
        for symbol_id, symbol in self.symbols.items():
            symbol["chama"] = callees.get(symbol_id, [])
            symbol["chamado_por"] = callers.get(symbol_id, [])
        links: dict[tuple[str, str], int] = {}
        for source, target in self.calls:
            a, b = self.symbols[source]["modulo"], self.symbols[target]["modulo"]
            if a != b:
                links[(a, b)] = links.get((a, b), 0) + 1
        return {"modulos": list(self.modules.values()), "simbolos": self.symbols,
                "ligacoes": [{"de": a, "para": b, "n": n} for (a, b), n in sorted(links.items())],
                "fontes": self.sources}


# ---------------------------------------------------------------- Python

class PythonReader:
    """Lê um módulo Python pelo `ast`: classes, funções, e as chamadas de cada função."""

    def __init__(self, graph: Graph, by_dotted: dict[str, str]):
        self.graph, self.by_dotted = graph, by_dotted
        self.pending: list[tuple[str, str, ast.AST, dict]] = []

    def dotted(self, path: str) -> str:
        stem = path.rsplit(".", 1)[0]
        return stem[: -len("/__init__")].replace("/", ".") if stem.endswith("/__init__") else stem.replace("/", ".")

    def read(self, path: str, text: str):
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")              # escapes antigos em strings não importam aqui
                tree = ast.parse(text)
        except SyntaxError:
            return
        imports: dict[str, tuple[str, str | None]] = {}   # nome local → (módulo, atributo ou None)
        package = self.dotted(path) if path.endswith("__init__.py") else self.dotted(path).rsplit(".", 1)[0]
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    imports[alias.asname or alias.name.split(".")[0]] = (alias.name if alias.asname else alias.name.split(".")[0], None)
            elif isinstance(node, ast.ImportFrom):
                base = node.module or ""
                if node.level:
                    parts = package.split(".")
                    parts = parts[: len(parts) - node.level + 1]
                    base = ".".join(parts + ([node.module] if node.module else []))
                for alias in node.names:
                    imports[alias.asname or alias.name] = (base, alias.name)
        scope = {"imports": imports, "locais": {}, "classes": {}}
        for node in tree.body:
            self.declare(path, node, None, scope)

    def declare(self, path: str, node: ast.AST, owner: str | None, scope: dict):
        if isinstance(node, ast.ClassDef):
            class_id = f"{path}#{node.name}"
            self.graph.add_symbol(path, class_id, nome=node.name, tipo="classe", dono=None,
                                  assinatura=f"class {node.name}({', '.join(ast.unparse(b) for b in node.bases)})",
                                  doc=(ast.get_docstring(node) or "").split("\n\n")[0],
                                  inicio=node.lineno, fim=node.end_lineno)
            scope["locais"][node.name] = class_id
            scope["classes"][node.name] = {"id": class_id, "metodos": {},
                                           "bases": [ast.unparse(b) for b in node.bases]}
            for child in node.body:
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    method_id = f"{class_id}.{child.name}"
                    scope["classes"][node.name]["metodos"][child.name] = method_id
                    self.function(path, child, method_id, node.name, scope)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            function_id = f"{path}#{node.name}"
            scope["locais"][node.name] = function_id
            self.function(path, node, function_id, None, scope)

    def function(self, path: str, node, symbol_id: str, owner: str | None, scope: dict):
        arguments = ast.unparse(node.args)
        returns = f" -> {ast.unparse(node.returns)}" if node.returns else ""
        self.graph.add_symbol(path, symbol_id, nome=node.name, tipo="método" if owner else "função", dono=owner,
                              assinatura=f"def {node.name}({arguments}){returns}",
                              doc=(ast.get_docstring(node) or "").split("\n\n")[0],
                              inicio=node.lineno, fim=node.end_lineno)
        self.pending.append((path, symbol_id, node, scope, owner))

    def resolve_module_attr(self, module: str, attr: str) -> str | None:
        path = self.by_dotted.get(module)
        if path is None:
            sub = self.by_dotted.get(f"{module}.{attr}")
            return None if sub is None else None
        candidate = f"{path}#{attr}"
        if candidate in self.graph.symbols:
            return candidate
        # o nome pode vir reexportado pelo __init__ do pacote
        reexport = self.reexports.get(path, {}).get(attr)
        return reexport

    def link_calls(self):
        self.reexports: dict[str, dict[str, str]] = {}
        for path, symbol_id, node, scope, owner in self.pending:
            for local, (module, attr) in scope["imports"].items():
                if attr is not None:
                    target_path = self.by_dotted.get(module)
                    if target_path and f"{target_path}#{attr}" in self.graph.symbols:
                        self.reexports.setdefault(path, {})[local] = f"{target_path}#{attr}"
        methods_by_name: dict[str, list[str]] = {}
        for symbol in self.graph.symbols.values():
            if symbol["tipo"] == "método" and symbol["modulo"].endswith(".py"):
                methods_by_name.setdefault(symbol["nome"], []).append(symbol["id"])
        # a fronteira com o núcleo: lib.aerosim_run(...) pelo ctypes chega na `export fn` de mesmo nome
        exports = {symbol["nome"]: symbol["id"] for symbol in self.graph.symbols.values()
                   if symbol["modulo"].endswith(".zig") and symbol["assinatura"].lstrip("pub ").startswith("export fn")}
        for path, symbol_id, node, scope, owner in self.pending:
            for call in ast.walk(node):
                if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr in exports:
                    self.graph.calls.add((symbol_id, exports[call.func.attr]))
                    continue
                if not isinstance(call, ast.Call):
                    continue
                target = self.target_of(call.func, path, scope, owner, methods_by_name)
                if target and target != symbol_id:
                    self.graph.calls.add((symbol_id, target))

    def target_of(self, func, path, scope, owner, methods_by_name) -> str | None:
        if isinstance(func, ast.Name):
            name = func.id
            if name in scope["locais"]:
                return scope["locais"][name]
            if name in scope["imports"]:
                module, attr = scope["imports"][name]
                return self.resolve_module_attr(module, attr) if attr else None
            return None
        if not isinstance(func, ast.Attribute):
            return None
        attr, base = func.attr, func.value
        if isinstance(base, ast.Name):
            if base.id in ("self", "cls") and owner:
                found = self.method_of(owner, attr, scope)
                if found:
                    return found
            elif base.id in scope["imports"]:
                module, sub = scope["imports"][base.id]
                full = f"{module}.{sub}" if sub else module
                if full in self.by_dotted:                              # import de módulo
                    return self.resolve_module_attr(full, attr)
                cls = self.resolve_module_attr(module, sub) if sub else None
                if cls and self.graph.symbols[cls]["tipo"] == "classe":  # Classe.metodo
                    candidate = f"{cls}.{attr}"
                    return candidate if candidate in self.graph.symbols else None
                return None
            elif base.id in scope["classes"]:
                return scope["classes"][base.id]["metodos"].get(attr)
        options = methods_by_name.get(attr, [])
        return options[0] if len(options) == 1 else None

    def method_of(self, owner: str, attr: str, scope: dict) -> str | None:
        seen = set()
        while owner and owner not in seen:
            seen.add(owner)
            cls = scope["classes"].get(owner)
            if cls is None:
                return None
            if attr in cls["metodos"]:
                return cls["metodos"][attr]
            owner = next((b for b in cls["bases"] if b in scope["classes"]), None)
        return None


# ---------------------------------------------------------------- Zig

CONTAINER = re.compile(r"\b(?:pub\s+)?const\s+(\w+)\s*(?::[^=]+)?=\s*(?:extern\s+|packed\s+)?(struct|enum|union)\b[^{;]*\{")
FUNCTION = re.compile(r"\b(?:pub\s+)?(?:export\s+|inline\s+|extern\s+)*fn\s+(\w+)\s*\(")
DECL = re.compile(r"\b(pub\s+)?const\s+(\w+)\s*=\s*([^;{]+);")
IMPORT = re.compile(r'@import\("([^"]+)"\)')
CALL = re.compile(r"(?<![\w.@])((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\s*\(")

KEYWORDS = {"if", "while", "for", "switch", "return", "fn", "catch", "orelse", "try", "and", "or", "struct", "enum",
            "union", "error", "comptime", "inline", "test", "defer", "errdefer", "suspend", "resume", "nosuspend"}


def strip_zig(text: str) -> str:
    """Troca comentários e textos entre aspas por espaços, sem mudar as posições, para ler só o código."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i) or text.startswith("\\\\", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def matching(code: str, open_at: int) -> int:
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return len(code) - 1


def line_of(code: str, offset: int) -> int:
    return code.count("\n", 0, offset) + 1


def doc_before(lines: list[str], line: int) -> str:
    docs = []
    i = line - 2
    while i >= 0 and lines[i].strip().startswith("///"):
        docs.append(lines[i].strip()[3:].strip())
        i -= 1
    return " ".join(reversed(docs))


class ZigReader:
    """Lê os .zig por texto: structs, funções, os `@import` e os apelidos, e as chamadas de cada função."""

    def __init__(self, graph: Graph, named: dict[str, str]):
        self.graph, self.named = graph, named
        self.scopes: dict[str, dict] = {}       # id do escopo (módulo ou struct) → {nome: (tipo, valor)}
        self.bodies: list[tuple[str, str, str, str]] = []   # (função, escopo, módulo, corpo)

    def read(self, path: str, text: str):
        code = strip_zig(text)
        lines = text.split("\n")
        self.scopes[path] = {}
        spans: list[tuple[int, int, str]] = []          # containers: início, fim, id
        for match in CONTAINER.finditer(code):
            open_at = match.end() - 1
            spans.append((match.start(), matching(code, open_at), match.group(1), match.group(2), open_at))

        def owner_at(offset: int) -> str:
            best, best_start = path, -1
            for start, end, name, _, open_at in spans:
                if open_at < offset <= end and start > best_start:
                    best, best_start = f"{path}#{self.qualified(spans, start, name, path)}", start
            return best

        for start, end, name, kind, open_at in spans:
            qualified = self.qualified(spans, start, name, path)
            container_id = f"{path}#{qualified}"
            parent = owner_at(start)
            self.scopes[container_id] = {}
            self.scopes[parent][name] = ("escopo", container_id)
            line = line_of(code, start)
            self.graph.add_symbol(path, container_id, nome=qualified, tipo=kind, dono=None,
                                  assinatura=lines[line - 1].strip(), doc=doc_before(lines, line),
                                  inicio=line, fim=line_of(code, end))
        for match in DECL.finditer(code):
            value = text[match.start(3):match.end(3)].strip()      # do texto original: o caminho do @import
            scope = owner_at(match.start())
            imported = IMPORT.fullmatch(value)
            if imported:
                self.scopes[scope].setdefault(match.group(2), ("import", self.import_target(path, imported.group(1))))
            elif re.fullmatch(r"[A-Za-z_][\w.]*", value):
                self.scopes[scope].setdefault(match.group(2), ("apelido", value, scope))
        for match in FUNCTION.finditer(code):
            name = match.group(1)
            paren = match.end() - 1
            depth, i = 0, paren
            while i < len(code):
                if code[i] == "(":
                    depth += 1
                elif code[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            j = i + 1
            while j < len(code) and code[j] not in "{;":
                if code.startswith("error{", j) or code.startswith("struct{", j):
                    j = matching(code, code.index("{", j)) + 1
                    continue
                j += 1
            if j >= len(code) or code[j] == ";":
                continue                                     # declaração sem corpo (extern)
            body_end = matching(code, j)
            scope = owner_at(match.start())
            function_id = f"{scope}.{name}" if scope != path else f"{path}#{name}"
            line = line_of(code, match.start())
            owner = scope.split("#", 1)[1] if "#" in scope else None
            signature = " ".join(text[match.start():j].split())
            self.graph.add_symbol(path, function_id, nome=name, tipo="método" if owner else "função", dono=owner,
                                  assinatura=signature, doc=doc_before(lines, line),
                                  inicio=line, fim=line_of(code, body_end))
            self.scopes[scope].setdefault(name, ("fn", function_id))
            self.bodies.append((function_id, scope, path, code[match.start():body_end]))

    @staticmethod
    def qualified(spans, start, name, path) -> str:
        parents = [n for s, e, n, _, o in spans if o < start <= e]
        parents_sorted = [n for s, e, n, _, o in sorted(spans) if o < start <= e]
        return ".".join(parents_sorted + [name]) if parents else name

    def import_target(self, path: str, spec: str) -> str | None:
        if spec.endswith(".zig"):
            return os.path.normpath(os.path.join(os.path.dirname(path), spec)).replace(os.sep, "/")
        return self.named.get(spec)

    def lookup(self, scope: str, name: str, depth: int = 0):
        """Acha `name` no escopo (e nos de fora, até o módulo) e devolve o escopo ou a função a que ele leva."""
        if depth > 12:
            return None
        current = scope
        while True:
            entry = self.scopes.get(current, {}).get(name)
            if entry:
                return self.follow(entry, depth)
            if "#" not in current:
                return None
            head, tail = current.split("#", 1)
            current = f"{head}#{tail.rsplit('.', 1)[0]}" if "." in tail else head

    def follow(self, entry, depth):
        kind = entry[0]
        if kind == "import":
            return ("escopo", entry[1]) if entry[1] in self.scopes else None
        if kind == "apelido":
            return self.chain(entry[2], entry[1].split("."), depth + 1)
        return entry

    def chain(self, scope: str, parts: list[str], depth: int = 0):
        found = self.lookup(scope, parts[0], depth)
        for part in parts[1:]:
            if not found or found[0] != "escopo":
                return None
            entry = self.scopes.get(found[1], {}).get(part)
            found = self.follow(entry, depth) if entry else None
        return found

    def variable_types(self, scope: str, body: str) -> dict[str, str]:
        """O tipo de cada variável e parâmetro que se lê sem inferência: `x: *Tipo`, `var x = Tipo.init(...)`, `Tipo{}`."""
        typed = {}
        for pattern in (VARIABLE, CONSTRUCTED):
            for match in pattern.finditer(body):
                found = self.chain(scope, match.group(2).split("."))
                if found and found[0] == "escopo":
                    typed.setdefault(match.group(1), found[1])
        return typed

    def link_calls(self):
        functions_by_name: dict[str, list[str]] = {}
        for symbol in self.graph.symbols.values():
            if symbol["modulo"].endswith(".zig") and symbol["tipo"] in ("função", "método"):
                functions_by_name.setdefault(symbol["nome"], []).append(symbol["id"])
        for function_id, scope, path, body in self.bodies:
            typed = self.variable_types(scope, body)
            for match in CALL.finditer(body):
                parts = match.group(1).split(".")
                if parts[-1] in KEYWORDS or parts[0] in KEYWORDS:
                    continue
                if len(parts) == 2 and parts[0] in typed:        # variavel.metodo(), com o tipo da variável
                    entry = self.scopes.get(typed[parts[0]], {}).get(parts[1])
                    if entry and entry[0] == "fn":
                        self.graph.calls.add((function_id, entry[1]))
                        continue
                found = self.chain(scope, parts)
                target = found[1] if found and found[0] == "fn" else None
                if target is None and len(parts) >= 2:
                    # x.metodo(): o tipo de x não é lido; vale só se o nome for único no projeto
                    options = functions_by_name.get(parts[-1], [])
                    target = options[0] if len(options) == 1 else None
                if target is None and found and found[0] == "escopo":
                    target = found[1]                       # Tipo(...) ou Tipo{...}: usa o tipo
                if target and target != function_id and target in self.graph.symbols:
                    self.graph.calls.add((function_id, target))


VARIABLE = re.compile(r"(?:\bvar|\bconst|[(,])\s*(\w+)\s*:\s*(?:\*|\?|\[\]|const\s+)*([A-Za-z_][\w.]*)")
CONSTRUCTED = re.compile(r"\b(?:var|const)\s+(\w+)\s*=\s*(?:try\s+)?([A-Za-z_][\w.]*?)(?:\.\w+\s*\(|\{)")



def named_modules() -> dict[str, str]:
    """Os módulos com nome (`@import("aerosim")`), lidos dos build.zig: createModule(root_source_file) e addImport."""
    named = {}
    for build in ("core/build.zig", "build.zig", "aerosim/build.zig", "aeroopt/build.zig", "aerodrive/build.zig"):
        full = os.path.join(ROOT, build)
        if not os.path.exists(full):
            continue
        text = open(full, encoding="utf-8").read()
        base = os.path.dirname(build)
        variables = {}
        for match in re.finditer(r"const (\w+) = b\.(createModule|addModule)\((?:\"(\w+)\",\s*)?[^;]*?b\.path\(\"([^\"]+)\"\)", text, re.S):
            target = os.path.normpath(os.path.join(base, match.group(4))).replace(os.sep, "/")
            variables[match.group(1)] = target
            if match.group(3):
                named[match.group(3)] = target               # b.addModule("aerosim", ...): o nome público
        for match in re.finditer(r'addImport\("(\w+)",\s*(\w+)\)|\.name = "(\w+)",\s*\.module = (\w+)', text):
            name, variable = (match.group(1), match.group(2)) if match.group(1) else (match.group(3), match.group(4))
            if variable in variables:
                named.setdefault(name, variables[variable])
    return named


def build() -> Graph:
    graph = Graph()
    files = source_files()
    by_dotted = {}
    for path in files:
        if path.endswith(".py"):
            stem = path[:-3]
            by_dotted[stem[: -len("/__init__")].replace("/", ".") if stem.endswith("/__init__") else stem.replace("/", ".")] = path
    python, zig = PythonReader(graph, by_dotted), ZigReader(graph, named_modules())
    for path in files:
        text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        graph.add_module(path, text, "zig" if path.endswith(".zig") else "py")
        (zig if path.endswith(".zig") else python).read(path, text)
    python.link_calls()
    zig.link_calls()
    return graph


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--saida", default=OUT, help="arquivo .json (padrão: zig-out/site/grafo.json)")
    parser.add_argument("--resumo", action="store_true", help="só imprime as contagens")
    args = parser.parse_args()
    data = build().to_json()
    functions = sum(1 for s in data["simbolos"].values() if s["tipo"] in ("função", "método"))
    called = sum(len(s["chama"]) for s in data["simbolos"].values())
    print(f"{len(data['modulos'])} módulos, {len(data['simbolos'])} símbolos ({functions} funções), "
          f"{called} chamadas, {len(data['ligacoes'])} ligações entre módulos")
    if not args.resumo:
        os.makedirs(os.path.dirname(args.saida), exist_ok=True)
        with open(args.saida, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        print(f"{os.path.relpath(args.saida, ROOT)}: {os.path.getsize(args.saida) // 1024} kB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
