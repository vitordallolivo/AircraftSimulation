# Tracking do projeto

Lista única do que o simulador cobre e do que falta. Junta as áreas de um projeto AeroDesign completo e as ideias de
`ideias.md`. É um juízo de valor, não uma análise: nada aqui foi calculado.

**Referência das áreas:** relatórios de projeto completos de uma equipe. Eles **não estão no git** e nenhum dado deles
entra aqui; servem só como lista do que um projeto cobre.

**Cuidado com estruturas:** os relatórios de referência têm valores inconsistentes nessa área. Servem como lista de
tópicos, nunca como fonte de números.

## Versões e escopo

- **Versão atual da `main`: `v0.1.0`.** É a primeira versão rastreada (sem tag ainda; ver Versionamento).
- **`1.0.0`:** todos os itens do **escopo 1.0** com ✅ na coluna **GUI**.
  - Uma análise só conta quando dá para rodá-la e ver o resultado pela interface.
  - Não contam o que só existe no código, numa ferramenta de linha de comando ou num teste.
- **Minor (`0.x.0`):** a cada PR mesclado na `main` que leva pelo menos um item do escopo 1.0 para ✅ na GUI.
- **Patch (`0.x.y`):** correção sem item novo.
- **Escopo:**
  - **1.0:** análises de projeto (seções 1 a 8) e itens de simulação que o usuário opera.
  - **pós-1.0:** ideias grandes e infraestrutura. Não entram na conta do progresso, mas ficam rastreadas.

**Legenda** (as duas colunas)
- **Código**
  - ✅ tem módulo e teste.
  - 🟡 parcial.
  - ❌ não existe.
  - ❓ a conferir.
- **GUI**
  - ✅ roda e mostra na interface.
  - 🟡 só parte.
  - ❌ não aparece.
  - ❓ a conferir.

Atualizar a cada PR. O progresso fica no fim do arquivo.

---

## 1. Aerodinâmica

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| AE-01 | Biblioteca de perfis, polares 2D por Reynolds, cache | ✅ | ✅ | 1.0 | `aero/sections.py`, `data/airfoils`, sprint Perfil |
| AE-02 | Asa finita: LLT, AVL, ASB, importar XFLR5 | ✅ | ✅ | 1.0 | aba Aerodinâmica, comparação de métodos |
| AE-03 | Asa por partições, perfil por seção | ✅ | ✅ | 1.0 | sprint Asa |
| AE-04 | Polar do avião completo (CL, CD, Cm × α) | ✅ | ✅ | 1.0 | aba Aerodinâmica → Polar |
| AE-05 | Dispositivos de ponta de asa | ✅ | ✅ | 1.0 | `aero/tipdevices.py` |
| AE-06 | Arrasto por componente (fuselagem, trem, empenagens, carenagem) | 🟡 | ❌ | 1.0 | só a área de arrasto da fuselagem |
| AE-07 | Downwash na cauda | 🟡 | 🟡 | 1.0 | empírico na simulação; nas cargas sai das ferraduras |
| AE-08 | Efeito solo (McCormick) | ✅ | ❓ | 1.0 | modifier `solo.mccormick` |
| AE-09 | Efeito solo por imagem e da mesa (só parte da asa sobre ela) | ❌ | ❌ | 1.0 | |
| AE-10 | Esteira da hélice nas superfícies | 🟡 | ❌ | 1.0 | `esteira.disco`; tubo reto, sem desvio; ligar pela GUI |
| AE-11 | Reynolds no núcleo (CLmax, CD0 por Re) | ❌ | ❌ | 1.0 | o núcleo usa valores fixos por superfície |
| AE-12 | Distribuição ao longo da envergadura a um α (início do estol) | ✅ | ❌ | 1.0 | `core/src/loads/llt.zig` |
| AE-13 | Comparação com ensaio (bancada / túnel) | ❌ | ❌ | 1.0 | entrada de dados de ensaio |
| AE-14 | CFD / 3D completo (estilo OpenVSP/Ansys, GPU) | ❌ | ❌ | pós-1.0 | `LoadResult` já aceita uma malha de CFD |
| AE-15 | Importar/exportar CAD (SolidWorks), rugosidade, arrasto parasita | ❌ | ❌ | pós-1.0 | |

## 2. Desempenho

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| DE-01 | Motor + hélice (tabela) + bateria | ✅ | ✅ | 1.0 | `physics/propulsion.zig`, Desempenho → Tração |
| DE-02 | Biblioteca de motores e hélices disponível de saída | 🟡 | 🟡 | 1.0 | perfis já estão; motores a conferir |
| DE-03 | Comparação de conjuntos motopropulsores (limites de corrente) | 🟡 | 🟡 | 1.0 | sprint Motores |
| DE-04 | Perda de tração por corpos atrás da hélice | ❌ | ❌ | 1.0 | |
| DE-05 | Ajuste de dados de ensaio dinâmico de hélice | ❌ | ❌ | 1.0 | a tabela aceita dados; falta o ajuste |
| DE-06 | Decolagem com pista limitada / mesa (6GDL) | ✅ | ✅ | 1.0 | Missão "só decolagem" |
| DE-07 | Decolagem com vento cruzado (controle no chão, tombamento) | ❌ | ❌ | 1.0 | |
| DE-08 | MTOW × altitude-densidade | ✅ | ✅ | 1.0 | envelope por altitude |
| DE-09 | Subida, voo nivelado, envelope | ✅ | ✅ | 1.0 | Desempenho |
| DE-10 | Curvas com fator de carga, dinâmicas | 🟡 | 🟡 | 1.0 | estático feito; falta o dinâmico com n |
| DE-11 | Planeio | ❓ | ❓ | 1.0 | |
| DE-12 | Pouso (distância, trajetória) | 🟡 | ❓ | 1.0 | `landingRun` no sizing |
| DE-13 | Consumo por fase de voo | 🟡 | 🟡 | 1.0 | bateria na missão |
| DE-14 | Massa total controlada na pista (não por LAPES/líquido) | ❓ | ❓ | 1.0 | `ideias.md` |
| DE-15 | Incerteza: Monte Carlo e sensibilidade ("chance de decolar em 6 m") | ❌ | ❌ | 1.0 | |
| DE-16 | Turbulência contínua (Dryden / von Kármán) | ❌ | ❌ | 1.0 | hoje só a rajada 1−cos |

## 3. Estabilidade e Controle

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| EC-01 | Estática longitudinal (PN, ME) | ✅ | ✅ | 1.0 | aba Estabilidade |
| EC-02 | ME × xCG com ênfase, faixa de CG | 🟡 | 🟡 | 1.0 | "Margem estática × posição do CG" existe; falta ênfase |
| EC-03 | Passeio do CG (soltura da LAPES, consumo do líquido) | 🟡 | 🟡 | 1.0 | "CG mais dianteiro/traseiro previsto" |
| EC-04 | Limite dianteiro do CG pela rotação na pista | ❓ | ❓ | 1.0 | conferir se a tesoura usa |
| EC-05 | Diagrama tesoura | ✅ | ✅ | 1.0 | |
| EC-06 | Trimagem (profundor por V e n) | ✅ | ✅ | 1.0 | |
| EC-07 | Dimensionamento de EH/EV e comandos | ✅ | ✅ | 1.0 | sprint Empenagem |
| EC-08 | Vento de través no pouso (leme, aileron) | ❓ | ❓ | 1.0 | |
| EC-09 | Taxa de rolamento (pb/2V) | ❓ | ❓ | 1.0 | |
| EC-10 | Dinâmica: modos e respostas | ✅ | ✅ | 1.0 | doublet, pulso |
| EC-11 | Qualidades de voo (MIL-F-8785C) | ✅ | ✅ | 1.0 | |
| EC-12 | Efeito do vento lateral/frontal na estabilidade | ❌ | ❌ | 1.0 | `ideias.md` |
| EC-13 | Polos com sloshing | ❌ | ❌ | 1.0 | `ideias.md` |
| EC-14 | Diedro elástico (flexão da asa) em Clβ/Cnβ | ❌ | ❌ | 1.0 | depende de ES-02 |
| EC-15 | Comparação com voo real (log de sensores) | ❌ | ❌ | 1.0 | |
| EC-16 | Inverter a rotação de qualquer motor | ❓ | ❓ | 1.0 | o núcleo tem `sense`; GUI a conferir |

## 4. Cargas

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| CA-01 | Distribuição de sustentação por superfície (V, n, rpm, com/sem hélice) | ✅ | ❌ | 1.0 | `aero/span_loads.py` |
| CA-02 | Vista 3D e gráficos das cargas | ✅ | ❌ | 1.0 | `LoadView`; ferramenta de linha de comando |
| CA-03 | Diagrama V-n de manobra | 🟡 | 🟡 | 1.0 | no envelope; sem os casos de carga tirados dele |
| CA-04 | Rajada por norma (fatores e V-n de rajada) | ❌ | ❌ | 1.0 | |
| CA-05 | Casos de manobra (rolamento, cabrada/picada, leme) | ❌ | ❌ | 1.0 | o 6GDL simula; falta montar os casos |
| CA-06 | Esforços internos: cortante, fletor, torsor | ❌ | ❌ | 1.0 | próximo passo a partir de CA-01 |
| CA-07 | Momentos de dobradiça | ❌ | ❌ | 1.0 | |
| CA-08 | Cargas no solo (pouso, taxiamento, uma roda) | ❌ | ❌ | 1.0 | |

## 5. Aeroelasticidade

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| AL-01 | Centro elástico e rigidez torcional | ❌ | ❌ | 1.0 | depende de ES-02 |
| AL-02 | Divergência | ❌ | ❌ | 1.0 | |
| AL-03 | Reversão de comando | ❌ | ❌ | 1.0 | |
| AL-04 | Modos de vibração e flutter | ❌ | ❌ | 1.0 | |
| AL-05 | Cargas dinâmicas (aeroelasticidade dinâmica) | ❌ | ❌ | pós-1.0 | `ideias.md` |

## 6. Estruturas

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| ES-01 | Massas e inércias | ✅ | ✅ | 1.0 | Montagem |
| ES-02 | Longarina da asa (flexão, deflexão, margem) | ❌ | ❌ | 1.0 | `ideias.md` |
| ES-03 | Tubo de cauda | ❌ | ❌ | 1.0 | `ideias.md` |
| ES-04 | Banco de materiais (fonte própria) | ❌ | ❌ | 1.0 | nunca dos relatórios de referência |
| ES-05 | Trem de pouso (eixo, garfo) | ❌ | ❌ | 1.0 | depende de CA-08 |
| ES-06 | Otimização estrutural | ❌ | ❌ | pós-1.0 | `ideias.md` |
| ES-07 | FEM / ensaio | ❌ | ❌ | pós-1.0 | caberia como importação de resultado |

## 7. Elétrica

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| EL-01 | Bateria de propulsão: C-rate × corrente de pico | 🟡 | ❌ | 1.0 | |
| EL-02 | Torque de servos por superfície | ❌ | ❌ | 1.0 | depende de CA-07 |
| EL-03 | Bateria dos servos, bitola dos cabos | ❌ | ❌ | 1.0 | |
| EL-04 | FMEA | ❌ | ❌ | pós-1.0 | documento, não simulação |

## 8. Integração / MDO / Projeto

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| IN-01 | MDO (PSO, pontuação) | ✅ | ✅ | 1.0 | página MDO |
| IN-02 | Projeto do zero em etapas (sprint por asa, em pasta) | ✅ | ✅ | 1.0 | `aerosim/design` |
| IN-03 | Montagem sem exigir decolagem; sprint direto em Desempenho | ✅ | ✅ | 1.0 | `ideias.md` (feito) |
| IN-04 | Tração e Missão dentro de Desempenho | ✅ | ✅ | 1.0 | `ideias.md` (feito) |
| IN-05 | xCG em % CMA | ✅ | ✅ | 1.0 | `ideias.md` (feito) |
| IN-06 | Checklist do avião | ✅ | ✅ | 1.0 | |
| IN-07 | Estimativa de peso vazio (banco histórico) | 🟡 | 🟡 | 1.0 | |
| IN-08 | Volume e arranjo da caixa | ❓ | ❓ | 1.0 | |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | 1.0 | |
| IN-10 | Tempo de missão no circuito real | 🟡 | 🟡 | 1.0 | |

## 9. Controle e configurações especiais

| ID | Tópico | Código | GUI | Escopo | Onde / observação |
|---|---|---|---|---|---|
| CO-01 | Piloto automático genérico (autotune) | ✅ | ✅ | 1.0 | AeroDrive e simulação |
| CO-02 | Aba de controle (controlador do simulador e um real) | ❌ | ❌ | 1.0 | `ideias.md` |
| CO-03 | Controle não linear (SMC, NN-MPC) | ❌ | ❌ | pós-1.0 | `ideias.md` |
| CO-04 | VTOL, tailsitter, eixos de motor que inclinam (análise não linear) | 🟡 | ❌ | pós-1.0 | o tilt existe no núcleo; falta a análise |
| CO-05 | Estabilidade de helicóptero (referência para VTOL) | ❌ | ❌ | pós-1.0 | `ideias.md` (pesquisa) |

## 10. Infraestrutura (não conta para a 1.0)

| ID | Tópico | Estado | Observação |
|---|---|---|---|
| IF-01 | Hash da ABI conferido ao carregar | ✅ | |
| IF-02 | Modifiers (métodos ligáveis sem mudar arquivos antigos) | ✅ | `core/src/modifiers` |
| IF-03 | Colisão do tubo da hélice | ✅ | `core/src/collision` |
| IF-04 | Integrador adaptativo (Dormand–Prince) com eventos | ❌ | |
| IF-05 | Derivadas exatas com números duais (comptime) | ❌ | |
| IF-06 | SIMD com painéis em estrutura de arrays | ❌ | medir antes com `bench.zig` |
| IF-07 | Paralelismo (PSO, Monte Carlo) | ❌ | |
| IF-08 | Testes de propriedade (energia, trimagem, linearização × diferenças finitas) | 🟡 | |
| IF-09 | Comparação bit a bit dos exemplos dentro do repositório | ❌ | hoje é um script fora do repositório |

---

## Progresso para a 1.0

Conta só os itens de escopo 1.0 das seções 1 a 9: ✅ na GUI / total. Os ❓ contam como não feitos até serem
conferidos.

**Onde foi medido:** na ponta da pilha (`docs/tracking`), não na `main`. Parte do que está ✅ aqui (sprint em
pasta, Tração/Missão dentro de Desempenho, xCG em % CMA, biblioteca de perfis) só chega na `main` quando a pilha for
mesclada.

| Seção | ✅ na GUI | Itens 1.0 |
|---|---|---|
| 1. Aerodinâmica | 5 | 13 |
| 2. Desempenho | 4 | 16 |
| 3. Estabilidade e Controle | 6 | 16 |
| 4. Cargas | 0 | 8 |
| 5. Aeroelasticidade | 0 | 4 |
| 6. Estruturas | 1 | 5 |
| 7. Elétrica | 0 | 3 |
| 8. Integração | 6 | 10 |
| 9. Controle | 1 | 2 |
| **Total** | **23** | **77** (30 %) |

## Próximos itens (ordem sugerida)

1. Conferir os ❓: são baratos e mudam a conta.
2. Fechar a pilha de branches na `main` (ver Versionamento) e criar a tag `v0.1.0` na `main` atual.
3. CA-03 → CA-04/CA-05 → CA-06: casos do V-n e esforços internos.
   - A conta da distribuição é da aerodinâmica (`aero` + `core/loads`).
   - Os casos e os esforços são da área de cargas.
4. CA-01/CA-02 na GUI: aba **Cargas**, com a vista 3D.
5. AE-10 na GUI (ligar a esteira por avião) e trimagem com a esteira.
6. CA-07 → EL-02: momentos de dobradiça → torque de servos.
7. ES-02/ES-04: longarina com materiais de fonte própria.
8. AE-11 (Reynolds no núcleo) e DE-15 (Monte Carlo).

---

## Versionamento

**Regras**
- Nada direto na `main`. Cada trabalho tem a sua branch; a `main` só recebe por PR.
- Uma branch por tema: `feature/<tema>`, `fix/<tema>`, `docs/<tema>`.
- Cada PR atualiza este arquivo (estado dos itens e progresso) e o `CHANGELOG.md`.
- Tag `vX.Y.Z` só na `main`, depois do merge.
- Relatórios e dados de terceiros nunca entram no git.

**Situação atual das branches** (em relação à `main`)
- A pilha `feature/sprint` → `feature/gui` → `feature/aero` → `feature/modifiers` → `docs/tracking` ainda não foi para
  a `main`.
- `feature/sprint` está atrás da `main`, porque já teve um PR mesclado. As outras saíram dela, então seguem em cadeia.
- `feature/aircraft-drive` e `claude/ecstatic-gates-u3lpoi` não têm nada a mais que a `main`.

**Para melhorar**
1. Tag `v0.1.0` na `main` atual, como ponto de partida.
2. Fechar a pilha em ordem, com um PR por branch, cada um com a sua validação (testes + comparação bit a bit). Cada
   PR que leva um item para ✅ na GUI sobe o minor.
3. Levar a comparação bit a bit para `tools/` ou `tests/` (IF-09).
4. Apagar as branches que já não têm nada a mais que a `main`, depois de confirmar.
