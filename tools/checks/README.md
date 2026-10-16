# tools/checks — checks de regressão

Confere que nada quebrou antes de um PR (milestone 0.1, tarefa T00 em `docs/TRACKING.md`).

```
python tools/checks/run.py                 # fundação, AeroDrive, regressão bit a bit, testes rápidos
python tools/checks/run.py --tudo          # + testes lentos (GUI, design, manager)
python tools/checks/run.py --grupos aerodrive
python tools/checks/run.py --so tests/aero
python tools/checks/run.py --ref feature/aero --rapido
python tools/checks/run.py --lista
python tools/checks/run.py --relatorio checks.md
```

Sai com código 1 se algum check falhar. Os pulados, por exemplo quando falta o zig, não contam como falha.

## Grupos

| grupo | o que roda |
|---|---|
| fundação | `zig build test` no `core/` |
| aerodrive | `zig build` e `zig build test` no `aerodrive/`; o AeroDrive importa o núcleo, então isso pega quebra de API |
| regressão | os exemplos de `data/aircraft` retratados no código atual e numa referência, comparados número a número |
| testes | uma pasta de `tests/` por check; uma pasta nova vira check sozinha |

## Regressão bit a bit

- **Referência:** `--ref` aceita um commit ou uma branch; o padrão é `origin/main`. Ela roda numa cópia separada do
  repositório (`git worktree`, em `~/.cache/aerosim-checks/trees/`), com o núcleo compilado a partir dela.
- **O que é retratado** (`snapshot.py`):
  - coeficientes do núcleo num quadro V × α × β;
  - trimagem nivelada em algumas velocidades;
  - resumo e log completo da missão "só decolagem". `--rapido` pula esta parte.
- **Cache:** um retrato por commit, em `~/.cache/aerosim-checks/`, fora do repositório. O código atual só entra no
  cache se não houver mudança local nos arquivos rastreados.
- **Diferença não é erro automático:** uma mudança de física pedida muda os números. O check lista o que mudou (avião,
  parte, maior diferença) e quem lê decide.

## Check novo

Uma função com `@check("grupo", "nome")` num módulo importado por `run.py`, devolvendo
`Result(ok, resumo, detalhes)`. `lento=True` faz o check rodar só com `--tudo`.

```python
from registry import Result, check

@check("fundação", "meu check")
def meu_check() -> Result:
    ...
    return Result(True, "tudo certo")
```
