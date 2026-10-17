# tools/aero — perfis de teste dos coeficientes

Aviões simples, **só superfícies** (sem fuselagem e sem motor), para comparar os coeficientes de cada método numa
velocidade típica (padrão 12 m/s). Os momentos são tomados no 1/4 da CMA da asa (a origem de cada caso). Tudo o que
sai (tabelas no terminal, gráficos e `valores.csv` com `--pasta`) fica fora do git.

| arquivo | o que tem |
|---|---|
| `casos.py` | `CASOS` (abaixo); `so(ac, partes)` deixa só asa, EH ou EV; `com_perfil(ac, arquivo.dat)` troca o perfil |
| `coeficientes.py` | as variantes do núcleo, o resumo (C_L0, C_Lα, C_m0, C_mα, C_D0, k), a distância até uma referência, a matriz entre os métodos, a varredura, os gráficos e a linha de comando |

## Comandos

```sh
python tools/aero/coeficientes.py --lista                       # casos, métodos e coeficientes
python tools/aero/coeficientes.py                               # tudo: todos os casos e métodos (~2 min)
python tools/aero/coeficientes.py --caso ret_ar8,enflechada --pasta perfis/aero   # gráficos e valores.csv
```

**Escolher o que roda:**

```sh
python tools/aero/coeficientes.py --metodos nucleo,nucleo_llt,avl           # só alguns métodos
python tools/aero/coeficientes.py --coef CLa,Cma,Clp,Cmq                     # só alguns coeficientes
python tools/aero/coeficientes.py --caso convencional --so ev --coef CYb,Cnb,Cnr,CYdr,Cndr   # só a EV
python tools/aero/coeficientes.py --caso convencional --so asa,eh            # asa + EH, sem a EV
python tools/aero/coeficientes.py --V 20                                     # outra velocidade
python tools/aero/coeficientes.py --perfil meu_perfil.dat                    # perfil .dat (Selig/Lednicer) na asa
python tools/aero/coeficientes.py --perfil eh.dat --perfil-em eh             # ... ou na EH
```

Com `--so`, a referência (S, c, b e a origem) continua a do avião inteiro, para que os números de cada parte se
somem. Sem a asa, a EH deixa de ver o downwash.

**Referência e proximidade:**

```sh
python tools/aero/coeficientes.py --ref avl --pasta perfis/aero              # distância até o AVL (padrão)
python tools/aero/coeficientes.py --ref lltdrek --pasta perfis/aero          # qualquer método vira a referência
python tools/aero/coeficientes.py --caso ret_ar8 --referencia asa.csv --ref csv --pasta perfis/aero   # um CSV de fora
python tools/aero/coeficientes.py --matriz --pasta perfis/aero               # cada método contra cada outro
```

O CSV de fora tem cabeçalho e colunas `alpha` (graus), `CL`, `CD`, `Cm` (as que houver; vírgula ou ponto e vírgula).
Ele entra nos gráficos da polar como curva preta tracejada.

**Malha e varredura:**

```sh
python tools/aero/coeficientes.py --paineis 8                                # malha fixa: 8 painéis por semiasa
python tools/aero/coeficientes.py --caso ret_ar8 --metodos nucleo_llt --varrer paineis=1,2,4,8,16,24 --pasta perfis/aero
python tools/aero/coeficientes.py --caso ret_ar8 --metodos avl,lltdrek --varrer V=8,12,16,20 --coef CLa,k
python tools/aero/coeficientes.py --perfil meu_perfil.dat --metodos lltdrek --varrer paineis=4,8,16 --pasta perfis/aero
```

`--paineis` divide a asa do `nucleo_fino` e do `nucleo_llt` (até o limite de 48 painéis do núcleo; acima, fica no
limite) e vai como `n_span` para os outros. Cada método tem o seu mínimo:
- o AVL e o lltdrek usam pelo menos 4;
- o VLM do ASB usa metade, com mínimo de 4 (a malha só muda acima de 8).

O `nucleo` fica sempre com a malha da simulação.

## Casos

| nome | o quê |
|---|---|
| `ret_ar4`, `ret_ar6`, `ret_ar8`, `ret_ar12` | asa retangular, corda 0,25 m |
| `trapezio` | AR 8, afilamento 0,5 |
| `enflechada` | `trapezio` com 25° no bordo de ataque |
| `diedro` | retangular AR 8 com 6° |
| `torcida` | `trapezio` com −3° na ponta |
| `asa_cauda` | retangular AR 8 com aileron + EH (AR 4) com profundor |
| `convencional` | `asa_cauda` + EV com leme |

Todas as asas usam NACA 2412, e as caudas NACA 0012. A geometria é de livro, sem fonte: o que se compara são os
métodos entre si e contra as referências de fora.

## Métodos

| nome | o quê |
|---|---|
| `nucleo` | núcleo, faixas da simulação (`core/src/physics/aero.zig`), com a malha da simulação: uma faixa por trecho entre seções (a asa trapezoidal é **um** painel por lado) |
| `nucleo_fino` | o mesmo, com a asa refinada (`--paineis`, ou o máximo que cabe) |
| `nucleo_solo25`, `nucleo_solo10` | o `nucleo` com o efeito solo (modifier padrão, McCormick) a h/b = 0,25 e 0,10 (`aerosim_aero_coeffs_at`) |
| `nucleo_llt` | núcleo, linha sustentadora (`core/src/loads/llt.zig`), asa refinada: soma das forças dos painéis. Sem taxas e sem o c_m do perfil |
| `lltdrek`, `asb_vlm`, `asb_buildup`, `avl` | os outros métodos de `aerosim.aero.all_solvers` (o AVL roda pelo OptVL) |

O único modifier que vale sem motor é o efeito solo. O de McCormick só mexe no arrasto induzido: o C_L e o C_m ficam
iguais, e o k cai pelo fator φ = (16 h/b)² / (1 + (16 h/b)²), que dá 16/17 a h/b = 0,25 e 2,56/3,56 a 0,10. O teste
confere esses valores. Os métodos com efeito solo ficam fora da distância e da matriz, porque são outro escoamento.

## Como se mede a distância

- **Erro relativo:** cada caso, método e coeficiente dá o erro em % contra a referência.
- **C_mα:** vira o **deslocamento do ponto neutro** em % da CMA, −ΔC_mα / C_Lα da referência (positivo: mais para
  trás). No 1/4 da CMA o C_mα é quase zero, e o erro relativo não diria nada.
- **Fica de fora** o coeficiente cuja |referência| é menor que 0,02 (ajustável com `--min-ref`; ex.: C_Yβ e C_nr da asa plana, quase zero).
- **Tabela:** a mediana de |erro| nos casos.
- **Matriz:** M[i, j] é a mediana de |erro| do método i tomando o j como referência, em todos os casos e
  coeficientes. Não é simétrica, porque o erro relativo divide pelo valor da referência.

**A referência não é a verdade.** O AVL é o padrão por ser o VLM mais validado que roda aqui, mas também erra: na asa
torcida ele dá C_L0 = 0,096, contra 0,040 a 0,066 de todos os outros. Contra experimento, só com dado de túnel ou de
voo (o Navion, em `tools/validacao`) ou com a asa do lltdrek que o dono vai mandar.

## Resultados (12 m/s; 17/10/2026)

### Distância até o AVL

![distância até o AVL](../../docs/img/aero_distancia_avl.png)

### Proximidade entre os métodos

![matriz de proximidade](../../docs/img/aero_matriz.png)

As linhas sustentadoras (`nucleo_llt` e `lltdrek`) ficam a 1 % uma da outra e a 2–4 % do AVL. As faixas do núcleo
ficam a uns 10 % do AVL, puxadas pelo k e pelas derivadas de taxa. O `asb_buildup` (uma soma de correlações) fica
longe de todos.

### Malha (asa retangular AR 8)

![varredura da malha](../../docs/img/aero_varredura_paineis.png)

### Polar da asa enflechada

![polar da enflechada](../../docs/img/aero_enflechada.png)

## Por que os métodos diferem

| diferença | causa | como se vê |
|---|---|---|
| ponto neutro da enflechada 10 % da CMA atrás, no `nucleo` | **malha**: um painel por lado põe a força no meio da semienvergadura. Num trapézio esse ponto fica fora da CMA (y_CMA < b/4); na enflechada, bem atrás | `nucleo_fino`: 0,9 % |
| C_L0 da asa torcida (0,050 contra 0,064) | a mesma: um painel só pega a torção média | `nucleo_fino`: 0,064, igual ao lltdrek |
| C_Lα igual com e sem enflechamento | o C_Lα da superfície é o de Helmbold (`aerosim/model/universal.py`), que só vê o alongamento | o AVL cai 1,6 % com 25° |
| k uns 15 % acima do AVL | o induzido das faixas é o da elipse com o Oswald fixo da superfície (`LiftingSurface.oswald` = 0,85) | a LLT do núcleo dá o k do AVL (1 %) |
| **C_lp** das faixas 20–50 % acima | as faixas usam o C_Lα 3D de Helmbold, que vale para a carga simétrica (α igual em toda a asa). Na rolagem a carga é antissimétrica: o downwash induzido é outro e a inclinação efetiva é menor. Com o C_Lα uniforme, a teoria das faixas dá C_lp = −C_Lα/6 na asa retangular (−0,78). O −0,59 da malha grossa é coincidência: uma faixa só em y = b/4 dá −C_Lα/8 | as linhas sustentadoras resolvem a carga antissimétrica: lltdrek −0,57 e AVL −0,51 (≈ 10 %). Nas LLTs o C_lp vai bem |
| **C_mq** da asa sozinha = 0 nas linhas sustentadoras (núcleo e lltdrek) | **é do método**. A linha sustentadora tem um ponto de controle por faixa, sobre a linha de 1/4 da corda. Arfando em torno do 1/4 da CMA, a linha passa pelo eixo e o α ali não muda. A rotação faz a velocidade normal variar ao longo da corda, como uma curvatura a mais, e essa curvatura só aparece com pontos ao longo da corda (o teorema de Pistolesi põe o ponto de controle aos 3/4 da corda; fonte: Katz e Plotkin, *Low-Speed Aerodynamics*, capítulo a conferir no PDF) | o VLM do ASB (−0,70) e o AVL (−0,72) têm painéis na corda e concordam. No avião inteiro o C_mq vem quase todo da EH (braço lt), e aí todos ficam a 5 % (−18,5 a −19,9) |
| C_lβ do diedro 1,4× o do AVL | o mesmo das taxas: o diedro gira o α de cada faixa com o C_Lα simétrico | T62 do TRACKING |
| **C_lβ ≠ 0 na asa plana** pela LLT do núcleo (0,03, e cresce com a malha: gráfico da malha) | **suspeita de erro** na LLT do núcleo com β | a investigar |
| **EV sozinha: C_Yβ e C_nβ da LLT do núcleo ≈ 2× os do AVL** (`--so ev`) | **suspeita de erro** na LLT do núcleo em superfície vertical (não espelhada) | a investigar; as faixas do núcleo ficam a 3–5 % do AVL |
| C_mα da enflechada pelas linhas sustentadoras (do núcleo e do lltdrek) | limite conhecido da linha sustentadora na quina da raiz enflechada (Goates e Hunsaker 2021) | o VLM e o AVL concordam entre si |
| C_L0 do VLM do ASB 12 % abaixo de todos | a conferir: talvez o VLM do ASB use só a linha média plana | — |
