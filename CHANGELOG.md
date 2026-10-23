# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## Não lançado

### v0.2.3 (branch `0.2_dev`)

- READMEs com as equações (T75): cada pasta do `core` (`physics`, `sim`, `control`, `math`, `sizing`, `loads`,
  `modifiers`, `collision`) e do `aerosim` tem as equações em LaTeX, uma por parágrafo, com a fonte, e um exemplo em
  Python por arquivo, que roda. Os tempos de máquina e os números de um caso só saíram dos READMEs (ficam em
  `core/OTIMIZACOES.md` e nos testes).
- Núcleo: enums no lugar dos bits. `core/src/opt.zig` (`Opt`) dá nome a cada bit do `-Dopt`, e o `build.zig` recusa um
  nome que não existe. Nos modificadores, `Ground`, `Kind` e `SlipstreamParam` dizem o que cada número seleciona. Os
  campos da ABI continuam `i32`, então o esquema e os `.cfg` não mudam.
- Aba Aerodinâmica com a linha sustentadora do núcleo (T67): `CoreLLTSolver` (`aerosim/aero/llt_solver.py`) em
  `all_solvers`, com duas variantes, `zig_llt` (Phillips e Snyder) e `zig_llt_gh` (Goates e Hunsaker). Liga em
  "comparar: linha sustentadora do núcleo"; desligado por padrão. As superfícies são refinadas
  (`span_loads.refine_all`, com os painéis por semiasa da aba). Os `nucleo_llt` e `nucleo_gh` de `tools/aero` passam a
  ser essa classe, com o mesmo resultado (o teste contra o MachUpX continua passando).
- Linha sustentadora mais rápida: a geometria fixa (nós, juntas de Goates e Hunsaker, segmentos ligados) é montada uma
  vez por configuração (`llt.prepare`, `Params.llt_cache`), e a cada avaliação só as pernas livres são calculadas.
  O resultado é bit a bit igual (teste em Zig). A decolagem com o `llt_gh` caiu de 107 para 10 s e com o `llt`, de
  21 para 12 s, na mesma máquina. Na missão de 165 s, em sequência: faixas 4 s, faixas refinadas 17 s, `llt` 261 s,
  `llt_gh` 258 s; os 9 modelos, 9 min 37 s (5 min 15 s em paralelo), contra mais de 1 h antes.
- `tools/aero/missao.py`: os voos rodam em paralelo (`--jobs`), e as tabelas de voo passam pelo cache de polares
  (`aerosim/aero/service.py`). O gráfico de tempo separa preparar de voar.
- Documentação: `tools/README.md` (índice das ferramentas, os três mapas de proximidade com os comandos, tempo de conta
  por modelo) e `core/OTIMIZACOES.md` (o que deixou a linha sustentadora rápida e o que se mediu).
- Correção: o lltdrek não ia para o cache em disco, porque o `cost = "caro"` estava no tradutor e não no solver.
- Voar com outro modelo aerodinâmico, fase B (T65): `Params.aero_model` escolhe o modelo da dinâmica, da trimagem e da
  linearização (`core/src/physics/aeromodel.zig`): 0 = faixas (o padrão: bit a bit igual, o AeroDrive não muda),
  1 = linha sustentadora (Phillips e Snyder ou Goates e Hunsaker), 2 = tabela do avião inteiro de qualquer método
  (`physics/aerotable.zig`; montada por `aerosim/aero/flight_table.py` com AVL, VLM, lltdrek...). No Python,
  `ac.sim.aero_model` e `ac.sim.aero_table`. `tools/aero/missao.py` voa a decolagem ou a missão com cada modelo e
  sobrepõe as curvas e o resumo da GUI (figuras em `docs/img/aero_*_modelos.png`).
- Decolagem com outro modelo, fase A (T65): `tools/aero/decolagem.py` roda a decolagem com o modelo de sempre e
  reavalia cada ponto com todos os métodos (núcleo, linha sustentadora, lltdrek, ASB, AVL) no mesmo estado: erro de
  cada coeficiente no tempo, RMS e máximo, em força (% do peso) e momento. `--puro` tira as sobrescritas e a fuselagem
  para todos verem o mesmo avião. Núcleo: `aerosim_aero_coeffs_llt` (os coeficientes do avião com as forças dos
  painéis pela linha sustentadora, com taxas, altura e tração); a simulação e o AeroDrive não mudam.
- Linha sustentadora de Goates e Hunsaker (T64; Goates e Hunsaker, AIAA SciTech 2021): a de Phillips e Snyder não
  converge com a malha em derrapagem nem com enflechamento (o C_lβ da asa plana crescia com o log da malha; o C_Lα da
  enflechada não parava). Três correções no `core/src/loads/llt.zig`, ligadas por `Params.llt_joint` e `llt_blend`
  (0 por padrão: tudo igual): junta das pernas, linha efetiva por ponto de controle e seção normal à linha. Contra o
  MachUpX (a implementação dos autores): C_Lα a 1,5 % e C_lβ a 3 % em quatro asas. Método novo na aba Cargas
  ("linha sustentadora (Goates e Hunsaker)", `llt_gh`) e no `tools/aero` (`nucleo_gh`).
- `tools/aero`: todas as superfícies são refinadas (antes só a asa; a EV sozinha saía com 2× o C_Yβ); figuras e matriz
  refeitas com o método novo.
- `tools/aero` (T63): perfis de teste dos coeficientes, só superfícies, a 12 m/s. Métodos: núcleo (malha da simulação
  e refinada), núcleo com efeito solo (McCormick a h/b = 0,25 e 0,10), linha sustentadora do núcleo, lltdrek, VLM e
  buildup do ASB, AVL. Distância até qualquer método ou CSV de fora (`--ref`), matriz entre os métodos (`--matriz`),
  coeficientes e superfícies escolhidos (`--coef`, `--so asa,eh,ev`), malha e varredura (`--paineis`,
  `--varrer paineis=...` ou `V=...`), perfil por .dat (`--perfil`). Figuras em `docs/img/aero_*.png`, README com as
  causas das diferenças (malha da simulação, Helmbold, Oswald fixo, faixas nas taxas, C_mq da linha sustentadora).
- Núcleo: `aerosim_aero_coeffs_at` (coeficientes com a altura sobre o chão, para o efeito solo); o resto igual.
- Tracking: T63, T64 (linha sustentadora do núcleo com β).
- Hélice no chão (T56): a falha "hélice tocou o chão" fica desligada por padrão (`ac.sim.prop_strike = False`,
  `Params.prop_strike = 0`): ligada, o exemplo `flying_wing` (pá 5,5 cm dentro do chão parado) não voava. A folga
  (`hprop`, `hpmin`) continua no registro.
- Desempenho → "Voo nivelado e envelopes" (T42): o envelope ganha aba; planilha e modelo completo sobrepostos
  (só com "os dois") ou cada um sozinho; o V-n sai daqui (vai para Cargas). Modelo completo: opção "abaixo do
  estol" (núcleo, desligada por padrão no `EnvCfg`) que continua a curva com a polar sem estol para achar o V_min
  de potência; V mínimo voável = max(V_min, V_e). Ângulo de cruzeiro vem do avião e pode ser mudado na aba;
  gráfico α de equilíbrio × V com o ângulo e o V_cru de cada método; diagnóstico do V_cru com o motivo e a faixa
  de α do envelope. Exportar ignora séries só de estilo.
- `docs/AREAS.md`: mapa das áreas e submódulos, com as duplicações encontradas; Desempenho por etapa de voo.
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
