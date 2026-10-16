# core/src/loads — distribuição de carga ao longo da envergadura

Só para **análise de cargas**. A simulação (`physics/aero.zig`) não chama nada daqui, então as corridas, a trimagem e
o AeroDrive ficam iguais.

## Por que existe

A simulação dá a cada faixa o C_Lα 3D da superfície inteira (Helmbold com o alongamento dela). Assim o alongamento
muda o **total**, mas a carga sai **plana** ao longo da envergadura: a ponta carrega tanto quanto a raiz. Para cargas
isso está errado. A ponta descarrega, e quanto menor o alongamento, mais a forma muda.

## Método: linha sustentadora numérica (`llt.zig`)

**Fonte:** Phillips, W. F. e Snyder, D. O., *Modern Adaptation of Prandtl's Classic Lifting-Line Theory*, Journal of
Aircraft 37(4), 662–670, 2000.

**Ferraduras:**
- uma ferradura por painel do núcleo;
- os dois nós ficam nos pontos de 1/4 de corda das **bordas** da faixa (`qa`, `qb` do painel, que o tradutor
  preenche). Faixas vizinhas dividem o nó, então as pernas se cancelam onde a circulação é igual, também com
  enflechamento e diedro. Sem os nós (`qa = qb = 0`, painéis montados à mão), o segmento sai do centro `r` com a
  largura `S/c`, perpendicular à corda, e só fecha as ferraduras numa superfície sem enflechamento;
- as pernas são retas e seguem o escoamento livre;
- o ponto de controle fica no centro `r` do painel, no meio do segmento ligado;
- a asa, a EH, a EV e os dispositivos entram juntos. Por isso o downwash da asa na cauda sai das pernas da asa, e não
  do ε empírico da simulação.

**Biot–Savart:** a velocidade induzida por um segmento reto vem de Katz e Plotkin, *Low-Speed Aerodynamics*, 2ª ed.,
cap. 10. O número da equação está a conferir no PDF.

**Equação, por painel:**

```
ρ |V_i| Γ_i = ½ ρ |V_i|² c_i η_i a_i (α_g,i − α0_i − (w_i · ez_i)/|V_i|),   w_i = Σ_j Γ_j w_ij
```

- `V_i`: velocidade local, já com os modificadores (esteira, solo).
- `α_g,i`: α do painel sem o downwash empírico, com os comandos.
- `α0_i = −C_L0/C_Lα`.
- `a_i`: inclinação 2D. Sai do C_Lα 3D do núcleo invertendo Helmbold, que é o que o tradutor usou:
  `a = C_Lα / √(1 − 2 C_Lα/(πAR))`. Com `1 − 2C_Lα/(πAR) ≤ 0`, usa 2π.

**Sistema linear:** n × n, com n ≤ 48, resolvido por eliminação de Gauss com pivô.

**Força:** Kutta–Joukowski no segmento ligado, `F = ρ Γ (V_ar × dl)`, com `dl` de nó a nó (inclui o enflechamento),
mais o arrasto de perfil `q S C_D0`.

**Segmentos ligados:** como em Phillips e Snyder, entram os segmentos ligados de todas as ferraduras, menos o do
próprio painel (a linha não induz nela mesma). São eles que fazem o enflechamento tirar sustentação: o segmento da
outra meia asa induz downwash perto da raiz.

**Por que mudou (outubro de 2026):** antes, a ferradura era montada em torno do centro da faixa e perpendicular à corda,
e os segmentos ligados da mesma superfície ficavam de fora. Numa superfície enflechada as ferraduras vizinhas não se
encontravam, e entre elas sobrava um pedaço de vórtice solto cujo efeito cresce como tan Λ / (largura da faixa). Nas
faixas estreitas da ponta isso explodia:
- winglet da asa voadora (enflechado): carga **crescendo** até a ponta, 45 N/m e α de 28° (o certo é cair até zero);
  com β = 5°, 697 N/m e α de 175°;
- asa enflechada de 25°: **ganhava** 20 % de sustentação contra a reta (o enflechamento tira sustentação).

Depois da correção: o winglet descarrega na ponta, e a asa enflechada perde sustentação (−2,5 %; no VLM do
AeroSandbox, −4,9 %).

**Núcleo dos vórtices entre superfícies:** usa o modelo de Scully (Vatistas, Kozel e Mih, *A simpler model for
concentrated vortices*, Experiments in Fluids 11, 1991, n = 1): `h² → h² + rc²`, com `rc = 0,1 c` de quem solta o
vórtice.
- Sem ele, a perna da raiz de uma EV que encosta na EH passa a milímetros dos pontos de controle da EH. No S1223 com
  hélice, isso dava 108 m/s induzidos e α de −93° na EH; no Convencional, uma EV com 7,8 N de força lateral falsa.
- Entre 0,05 e 0,25 da corda o resultado quase não muda.
- Dentro da mesma superfície não há núcleo: a queda na ponta depende das pernas das faixas vizinhas, que são mais
  estreitas que qualquer núcleo dessa ordem. Um núcleo de 0,05 c ali levava a ponta da asa de 9 para 54 N/m.

## Limites conhecidos

- **Quinas (raiz de asa com diedro ou enflechamento):** ali a linha sustentadora de Phillips e Snyder é singular. O
  segmento ligado da outra meia asa passa perto do ponto de controle da faixa da raiz, e o valor na raiz depende da
  malha: na asa do Convencional (3° de diedro) a raiz fica +1,4 %, +2,6 % e +3,3 % acima de y = 0,3 m com 8, 16 e 24
  faixas por lado; numa asa enflechada de 25°, o contrário, um vale. A sustentação total converge (118,1 → 117,1 →
  116,9 N). A correção é a de Reid e Hunsaker (2020): suavizar o lugar dos centros aerodinâmicos perto de cada ponto
  de controle. Ainda não feita (tarefa T55): a equação está a conferir no artigo.
- **Linear:** c_l = a(α − α0), sem estol. Perto do C_Lmax, a carga real é menor.
- **Pernas retas:** não se enrolam nem se desviam pela esteira da hélice.
- **Trimagem:** α e profundor vêm da trimagem da simulação. A soma das cargas pode ficar uns poucos % fora do peso,
  e o momento de arfagem não fica exatamente zerado.
- **Discretização:** a convergência é lenta com faixas iguais. `span_loads` refina com faixas mais estreitas na ponta
  (`y = y0 + (y1 − y0)·sen(πt/2)`), como Phillips e Snyder recomendam. Na asa do Convencional, de 34 para 44 faixas a
  sustentação muda 0,25 %.

## Como chamar

- **Export:** `aerosim_panel_states_llt` (em `root.zig`), com os mesmos argumentos de `aerosim_panel_states`. Devolve
  os mesmos `PanelState`, com `alpha` (efetivo), `CL`, `L`, `D`, `F` e `v`/`vind` da linha sustentadora.
- **Python:** `session.panel_states(..., llt=True)` e `aerosim.aero.span_loads.LoadCase(method="llt")`, que é o padrão.
  `method="faixas"` dá a carga plana da simulação.

## Testes (`zig build test-physics`)

- Helmbold invertido volta à inclinação 2D do perfil.
- Um segmento muito longo dá Γ/(2πh), o vórtice infinito.
- Na asa retangular, a ponta fica descarregada, a carga é simétrica e o C_L fica a menos de 6 % de Helmbold. Com
  alongamento menor, o C_L também é menor.
- Com diedro, a raiz não salta mais que 1 % (no VLM do AeroSandbox: +0,25 % a 3°, +0,9 % a 10°).
- Núcleo de Scully: finito em cima da linha e metade do valor sem núcleo a h = rc.
- Cauda em T: o painel da EH ao lado da raiz da EV não salta. Sem o núcleo, esse painel dá 5 vezes a carga dos
  vizinhos, e o teste falha.

Em Python (`tests/aero/test_span_loads.py`):
- o winglet enflechado da asa voadora descarrega na ponta, com e sem β;
- o enflechamento tira sustentação (tendência do VLM do AeroSandbox; os números não precisam bater, o VLM resolve a
  corda e a linha sustentadora não);
- a sustentação da asa converge ao refinar a malha.

## Como validar (o que é referência e o que não é)

- **Consistência do método:** o resultado tem de convergir com o refino. Um valor que muda com a malha (a quina da
  raiz) é erro do método, não física.
- **Outro método (só tendência):** o VLM do AeroSandbox (`aero/asb_solver.py`). Ele resolve a corda e dá números
  diferentes; serve para conferir o sentido dos efeitos (enflechamento, winglet, diedro).
- **Ensaio (o número esperado no teste):**
  - Stuper, J., *Effect of Propeller Slipstream on Wing and Tail*, NACA TM 874, 1938: asa retangular AR 4 (0,8 m ×
    0,2 m), com e sem jato de +18 % e +36 %, α de 4°, 8° e 12°. Usado por Hunsaker e Snyder (abaixo) para validar
    exatamente este método;
  - Montoya, L. C., Flechner, S. G. e Jacobs, P. F., *Effect of an Alternate Winglet on the Pressure and Spanwise
    Load Distributions of a First-Generation Jet Transport Wing*, NASA TM 78786, 1978: cargas ao longo da envergadura
    com e sem winglet (o winglet aumenta a carga perto da ponta da asa). Modelo transônico e enflechado de 35°: serve
    para a tendência.

## Referências

- Phillips, W. F. e Snyder, D. O., *Modern Adaptation of Prandtl's Classic Lifting-Line Theory*, Journal of Aircraft
  37(4), 662–670, 2000. O método.
- Hunsaker, D. F. e Snyder, D. O., *A Lifting-Line Approach to Estimating Propeller/Wing Interactions*, AIAA. O mesmo
  método com nós no 1/4 de corda (eq. 4 a 15, versão não linear por Newton), mais a esteira por elemento de pá
  (eq. 21 a 24), validados contra Stuper. Conclusão deles: com hélice, "qualitativamente correto, quantitativamente
  otimista".
- Reid, J. T. e Hunsaker, D. F., *General Approach to Lifting-Line Theory, Applied to Wings with Sweep*, Journal of
  Aircraft, 2020, doi:10.2514/1.C035994. A correção das quinas (a conferir no PDF).
- Goates, C. D. e Hunsaker, D. F., *Practical Implementation of a General Numerical Lifting-Line Method*, AIAA
  SciTech 2021. A versão geral (MachUpX).
- Katz, J. e Plotkin, A., *Low-Speed Aerodynamics*, 2ª ed., Cambridge, 2001, cap. 10. Segmento de vórtice reto.
- Vatistas, G. H., Kozel, V. e Mih, W. C., *A simpler model for concentrated vortices*, Experiments in Fluids 11,
  1991. Núcleo de Scully.

Os PDFs não ficam no repositório (regra 7 do `.claude/CLAUDE.md`): só a citação.
