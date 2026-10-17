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

## Método de Goates e Hunsaker (ligável, `llt_joint` e `llt_blend`)

**Fonte:** Goates, C. D. e Hunsaker, D. F., *Practical Implementation of a General Numerical Lifting-Line Method*, AIAA
SciTech 2021 (a forma prática do método de Reid e Hunsaker 2020). Os autores o implementam no MachUpX
(github.com/usuaero/MachUpX), que serviu de referência nos testes.

**Por que:** o método de Phillips e Snyder "não converge com a malha para asas enflechadas ou em derrapagem" (G-H
§II.A, p. 4). Duas singularidades:
- **em derrapagem**, as pernas seguem o vento e saem inclinadas no plano da asa. Cada perna induz (1 + sen β) de um
  lado e (1 − sen β) do outro, e a parte assimétrica soma ΔΓ/|Δy| sem trocar de sinal. O C_lβ da asa plana AR 8 ia
  de 0,0055 a 0,029 entre 1 e 24 faixas por lado, crescendo com o log da malha;
- **com enflechamento ou diedro**, a quina da raiz (ver Limites abaixo).

**As três correções** (só com `Params.llt_joint > 0` ou `Params.llt_blend > 0`):
1. **Junta** (eq. 3 e 17): cada perna sai do nó por um trecho de δ·c_nó no plano da asa, perpendicular à linha
   sustentadora (u_aΛ, eq. 12–15), e só depois segue o escoamento livre. δ = 0,15.
2. **Linha sustentadora efetiva** (eq. 7): para cada ponto de controle i, os nós da mesma asa são misturados com a
   reta tangente à linha em i, com peso exp(−σ (s − s_i)²). Sem curvatura em i, a quina deixa de ser singular. s é o
   comprimento ao longo da linha projetado em y-z, em metros, e σ = (2 / (b_seg Δ cos Λ_i))², com b_seg a
   semienvergadura (a forma dimensional do MachUpX, `airplane.py`; o artigo escreve com s adimensional, eq. 8).
   Δ = 1,0 (o padrão do MachUpX; o artigo usou 0,25 na validação, p. 19). As juntas também usam u_a misturado.
3. **Seção no plano normal à linha** (§IV): o α da seção é tomado com a velocidade projetada nesse plano (eq. 24–27);
   a corda vira c cos Λ (eq. 21), o α0 vira α0/cos Λ (eq. 35) e o comando, δ_fΛ = asin(cos Λ sen δ_f) (eq. 23).

As asas são as cadeias de painéis do mesmo grupo que dividem nós. Um ponto de controle vê as outras asas com a geometria
original (G-H §III.A). A corda num nó é a média dos dois painéis que o dividem.

**Contra o MachUpX** (α = 2°, perfil linear a = 5,9/rad, α0 = −2,11°; casos de `tools/aero`):

| caso | C_Lα núcleo | C_Lα MachUpX | C_lβ núcleo | C_lβ MachUpX | C_lβ Phillips e Snyder (24 faixas) |
|---|---|---|---|---|---|
| retangular AR 8 | 4,630 | 4,600 | 0,0125 | 0,0125 | 0,029 (não converge) |
| diedro 6° | 4,598 | 4,568 | −0,0852 | −0,0838 | −0,069 (não converge) |
| trapezoidal λ 0,5 | 4,727 | 4,700 | 0,0194 | 0,0193 | 0,034 (não converge) |
| enflechada 25° | 4,557 | 4,539 | −0,0338 | −0,0333 | −0,018; C_Lα 4,69 sem convergir |

O C_lβ positivo da asa plana é do modelo de esteira alinhada ao vento (o MachUpX dá o mesmo); o AVL e o VLM põem a
esteira no eixo x e dão 0.

**Como ligar:** `Params.llt_joint = 0,15` e `Params.llt_blend = 1,0`. No Python, `aerosim.aero.span_loads.GOATES_HUNSAKER`
vai como `overrides` da sessão; a aba Cargas tem o método "linha sustentadora (Goates e Hunsaker)" (`llt_gh`). Com os
dois em 0 (o padrão), a linha sustentadora é a de Phillips e Snyder, com as mesmas contas de antes.

## Limites conhecidos

- **Quinas (raiz de asa com diedro ou enflechamento):** ali a linha sustentadora de Phillips e Snyder é singular. O
  segmento ligado da outra meia asa passa perto do ponto de controle da faixa da raiz, e o valor na raiz depende da
  malha: na asa do Convencional (3° de diedro) a raiz fica +1,4 %, +2,6 % e +3,3 % acima de y = 0,3 m com 8, 16 e 24
  faixas por lado; numa asa enflechada de 25°, o contrário, um vale. A sustentação total converge (118,1 → 117,1 →
  116,9 N). A correção é a linha sustentadora efetiva de Goates e Hunsaker (seção acima), ligável. Em derrapagem, o
  mesmo vale para as pernas inclinadas: use o método de Goates e Hunsaker.
- **Alongamento baixo:** a linha sustentadora superestima o C_Lα. Na EV sozinha de AR 1,25 de `tools/aero`, o C_Yβ
  fica uns 25 % acima do AVL, mesmo convergido.
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
- **Coeficientes do avião com a linha sustentadora:** `aerosim_aero_coeffs_llt` (`llt.coeffs`), com os mesmos
  argumentos de `aerosim_aero_coeffs_at` (taxas p, q, r; altura sobre o chão; tração e torque de cada motor; ponto dos
  momentos). Faz a conta da simulação (`aero.computeTrace`) e troca só as forças dos painéis pelas de `apply`, então
  a fuselagem, o c_m das seções, o efeito solo e a esteira continuam os da simulação. C_Di sai NaN. No Python:
  `session.aero_coeffs_llt(...)`. A simulação e o AeroDrive não chamam (é a base da fase B de `tools/aero/decolagem.py`).
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
- Derrapagem: o C_lβ de Phillips e Snyder muda mais de 10 % de 20 para 40 faixas (não converge); o de Goates e
  Hunsaker muda menos de 3 % e fica a 5 % do MachUpX (0,01524 a α = 0,08 rad, a = 2π).
- Goates e Hunsaker desligado por padrão.

Em `tests/tools/test_aero_perfis.py`: o C_Lα (1,5 %) e o C_lβ (3 %) de Goates e Hunsaker contra o MachUpX nos quatro
casos da tabela acima.

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
  Aircraft, 2020, doi:10.2514/1.C035994. A base do Goates e Hunsaker (não temos o PDF; as equações usadas são as do
  Goates e Hunsaker).
- Goates, C. D. e Hunsaker, D. F., *Practical Implementation of a General Numerical Lifting-Line Method*, AIAA
  SciTech 2021. As equações implementadas (eq. 3, 7, 12–17, 21, 23–27, 35) e a referência numérica (MachUpX).
- Katz, J. e Plotkin, A., *Low-Speed Aerodynamics*, 2ª ed., Cambridge, 2001, cap. 10. Segmento de vórtice reto.
- Vatistas, G. H., Kozel, V. e Mih, W. C., *A simpler model for concentrated vortices*, Experiments in Fluids 11,
  1991. Núcleo de Scully.

Os PDFs não ficam no repositório (regra 7 do `.claude/CLAUDE.md`): só a citação.
