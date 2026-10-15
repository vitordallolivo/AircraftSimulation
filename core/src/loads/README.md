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
- o segmento ligado fica a 1/4 da corda (o centro `r` do painel), com a largura `S/c`;
- as pernas são retas e seguem o escoamento livre;
- o ponto de controle fica no meio do segmento ligado;
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

**Força:** Kutta–Joukowski no segmento ligado, `F = ρ Γ (V_ar × dl)`, mais o arrasto de perfil `q S C_D0`.

**Mesma superfície:** como na teoria de Prandtl, a linha sustentadora não induz velocidade nela mesma. Entre painéis
da mesma superfície (mesmo grupo, como as duas meias asas) entram só as pernas. Phillips e Snyder somam também os
segmentos ligados das outras ferraduras. Numa quebra de diedro, o segmento da outra meia asa passa a milímetros do
ponto de controle e cria um pico na raiz que depende da discretização: com 3° de diedro, +3 %. Esse pico tem teste.

## Limites conhecidos

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
- Com diedro, não aparece pico na raiz.
