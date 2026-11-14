# tools — ferramentas do repositório

Estes scripts montam o site e o pacote, refazem o mapa do código e rodam os checks. Nenhum deles faz conta do avião:
o cálculo fica no núcleo (`core/`) e nas telas em Zig. O que eles gravam fica fora do git (`zig-out/`, `dist/` ou a
pasta que você passar), com exceção do `docs/MAP.md`, que entra no git.

| ferramenta | o que faz |
|---|---|
| `checks/run.py` | os checks: núcleo, AeroDrive, mapa do código, regressão bit a bit dos exemplos contra a `main`, testes por área (`--tudo` inclui os lentos). Ver `checks/README.md` |
| `codemap.zig` | refaz `docs/MAP.md` a partir do código (`zig build mapa`; `-- --check` só confere) |
| `grafo.zig` | o mapa do código do site: o grafo das funções, com quem chama quem |
| `livro.zig` | `zig build site`: monta o site (`livro.html`): todos os `.md` do repositório como capítulos, com equações (KaTeX), diagramas (mermaid) e imagens, mais o mapa do código e o tracking ao lado |
| `tracking.zig` | `zig build tracking`: gera a página do tracking (`tracking.html`) das tabelas do Quadro do `docs/TRACKING.md` (`-- --check` só confere as tabelas; `--feito`, `--estado` e `--issue` mudam o .md, o `--issue` é o que a Action `tracking.yml` usa) |
| `web_build.py` | compila o AeroDrive, o aerosim e o aeroopt para o navegador e monta o site |
| `package.py` | monta o programa instalável (AppImage do Linux, instalador do Windows) |
| `templates_zig.py` | gera `aerosim/model/templates.zig`, os aviões de exemplo da Montagem |

```sh
python tools/checks/run.py            # os checks rápidos
python -m ziglang build mapa          # refaz o mapa do código
python -m ziglang build site          # o livro, o mapa e o tracking em zig-out/site
python tools/web_build.py             # o site com os programas no navegador
python tools/package.py               # o pacote do Linux em dist/
```
