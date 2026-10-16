# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## Não lançado

### v0.2.3 (branch `0.2_dev`)

- Aba Cargas (T12): a carga ao longo de cada superfície num ponto de voo (V, n, α da trimagem ou imposto), com e
  sem a hélice do conjunto motopropulsor do avião, pela linha sustentadora (`core/src/loads/llt.zig`) ou pelas
  faixas da simulação. Gráficos de L', α efetivo e V/V∞ por superfície e a vista 3D (`LoadView`) dentro da aba
  (tipo de gráfico `loads3d`). Diagnóstico: trimagem, soma das cargas × n·peso e esteira desligada.
- Tracking: regras (norma e restrição só por preset do usuário; conta no núcleo; cargas é análise tardia), o fluxo
  de projeto e as tarefas T37 a T41.
- `.claude/CLAUDE.md`: seção do ambiente (o que instalar e problemas conhecidos).
- Missão: fator de carga nas curvas (T06). O gráfico "Fator de carga" mostra, junto do n_z, o n que a inclinação
  pede (curva nivelada, 1/cos φ), o n em que a asa estola na V do momento (n_z C_Lmax/C_L) e o n estrutural; os
  instantes com C_L = C_Lmax ficam marcados. Só em voo (Anderson, Introduction to Flight, §6.17).
- Missão, análise "curvas: raio mínimo": gráfico novo "Curvas: fator de carga no tempo" (n_z e n no estol por raio)
  e o n no estol em regime no "Fator de carga × raio"; coluna `n_estol_perm` nos casos.
- `docs/TRACKING.md`: tira as linhas duplicadas AE-08 a AE-10; versão da `main` em dia (`v0.2.2`); os ❓ que
  sobraram conferidos no código (EC-08, EC-09 e EC-16 ✅; IN-08 ❌; DE-02 sem tarefa); progresso medido na `main`.

## v0.2.2 — PR #27

- `.claude/CLAUDE.md`: guia de desenvolvimento (objetivo, conceitos, decisões de projeto, fluxo de git e versões,
  métricas, comandos).
- `tools/codemap.py` → `docs/MAP.md`: mapa do código gerado; check "mapa do código em dia" em `tools/checks`.

## v0.2.1 — PR #26

- Missão: passeio do CG e margem estática ao longo do voo (T04).
- Tracking: versão por tarefa (`0.2.x`) até a lista inteira virar `0.3.0`; elétrica fora do escopo; branch única
  `0.2_dev`.

## v0.2.0 — fundação fechada (PRs #24–#25)

- `tools/checks`: checks de regressão (núcleo Zig, AeroDrive, exemplos bit a bit contra uma referência, testes por
  área).
- `docs/TRACKING.md`: castelo, milestones, quadro de tarefas com dependências; T01 conferido.

## v0.1.x — pilha de branches mesclada (PRs #21–#23)

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

## v0.1.0 — ponto de partida (`main` em `033bdc1`)

Primeira versão rastreada. É a `main` depois dos PRs 11, 12 e 13.
- Simulação 6GDL e GUI com Aerodinâmica, Desempenho, Estabilidade e Montagem.
- AeroDrive.
- Projeto do zero (sprint).
