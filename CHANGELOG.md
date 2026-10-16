# Changelog

Versões da `main`. Critério de versão e escopo da 1.0 em `docs/TRACKING.md`.

## Não lançado

### v0.2.1 (branch `0.2_dev`, PR aberto)

- `.claude/CLAUDE.md`: guia de desenvolvimento (objetivo, conceitos, decisões de projeto, fluxo de git e versões,
  métricas, comandos).
- `tools/codemap.py` → `docs/MAP.md`: mapa do código gerado; check "mapa do código em dia" em `tools/checks`.
- Missão: passeio do CG e margem estática ao longo do voo (T04).
- Tracking: versão por tarefa (`0.2.x`) até a lista inteira virar `0.3.0`; elétrica fora do escopo.

### v0.2.0 — fecha o milestone 0.1 (branch `test/checks`)

- `tools/checks`: checks de regressão (núcleo Zig, AeroDrive, exemplos bit a bit contra uma referência, testes por
  área).
- `docs/TRACKING.md`: castelo, milestones, quadro de tarefas com dependências; T01 conferido.

## v0.1.x — pilha mesclada (PRs #21–#23)
## Não lançado (pilha de branches ainda fora da `main`)

`feature/sprint` → `feature/gui` → `feature/aero` → `feature/modifiers` → `docs/tracking`

**Projeto**
- Sprint por asa, em pasta.
- Montagem sem exigir decolagem.
- Tração e Missão dentro de Desempenho.
- xCG em % CMA.
- Biblioteca de perfis disponível de saída.

**Aerodinâmica**
- Camada 2D de polares com cache.
- Cache 3D.
- AVL e importação do XFLR5.

**Modifiers**
- Efeito solo (McCormick) e esteira da hélice por disco atuador, ligáveis por avião e desligados por padrão.

**Colisão**
- Tubo da hélice contra superfícies e objetos.

**Cargas**
- Distribuição ao longo da envergadura pela linha sustentadora (Phillips e Snyder 2000), com e sem hélice.
- Vista 3D no modelo da GUI.

**Núcleo**
- Hash da ABI conferido ao carregar.

**Documentação**
- `docs/TRACKING.md` e este arquivo.

## v0.1.0 — ponto de partida (`main` em `033bdc1`)

Primeira versão rastreada. É a `main` depois dos PRs 11, 12 e 13.
- Simulação 6GDL e GUI com Aerodinâmica, Desempenho, Estabilidade e Montagem.
- AeroDrive.
- Projeto do zero (sprint).
