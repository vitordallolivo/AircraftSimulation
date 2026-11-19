# tools — ferramentas do repositório

Estas ferramentas montam o site e o pacote, refazem o mapa do código e rodam os checks. Nenhum deles faz conta do avião:
o cálculo fica no núcleo (`core/`) e nas telas em Zig. O que eles gravam fica fora do git (`zig-out/`, `dist/` ou a
pasta que você passar), com exceção do `docs/MAP.md`, que entra no git.

A regressão retrata os exemplos no código atual e numa cópia da referência (`git worktree`, em
`~/.cache/aerosim-checks/trees/`), um retrato por commit no mesmo cache, e compara número a número. Uma diferença não
é erro automático: uma física nova pedida muda os números, e o check diz o que mudou (avião, análise, campo e a maior
diferença) para quem lê decidir. No GitHub Actions o mesmo `zig build check -- --tudo` roda a cada PR para a `main`
(`.github/workflows/testes.yml`), com o relatório em Markdown nos Artifacts.

| ferramenta | o que faz |
|---|---|
| `check.zig` | `zig build check`: os testes do núcleo, do aerosim e do AeroDrive, o mapa do código, o tracking, as equações dos `.md` e a regressão dos exemplos contra a `main` (`-- --tudo` inclui a Missão e as asas; `--grupos`, `--so`, `--ref`, `--relatorio`, `--lista`) |
| `retrato.zig` | `zig build retrato` (de `aerosim/`): passa os aviões de `data/aircraft` pelas análises do aerosim e grava o resultado de cada uma; é o que a regressão compara |
| `codemap.zig` | refaz `docs/MAP.md` a partir do código (`zig build mapa`; `-- --check` só confere) |
| `grafo.zig` | o mapa do código do site: o grafo das funções, com quem chama quem |
| `livro.zig` | `zig build site`: monta o site (`livro.html`): todos os `.md` do repositório como capítulos, com equações (KaTeX), diagramas (mermaid) e imagens, mais o mapa do código e o tracking ao lado |
| `tracking.zig` | `zig build tracking`: gera a página do tracking (`tracking.html`) das tabelas do Quadro do `docs/TRACKING.md` (`-- --check` só confere as tabelas; `--feito`, `--estado` e `--issue` mudam o .md, o `--issue` é o que a Action `tracking.yml` usa) |
| `pacote.zig` | `zig build pacote`: monta o programa instalável (AppImage do Linux, instalador do Windows; `-- --alvo windows`) ou o site com os programas no navegador (`-- --alvo web`) |

```sh
python -m ziglang build check         # os checks (-- --tudo: a regressão inteira)
python -m ziglang build mapa          # refaz o mapa do código
python -m ziglang build site          # o livro, o mapa e o tracking em zig-out/site
python -m ziglang build pacote -- --alvo web   # o site com os programas no navegador
python -m ziglang build pacote        # o pacote do Linux em dist/
```
