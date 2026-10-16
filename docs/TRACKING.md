# Tracking do projeto

Onde o simulador está em relação às áreas de um projeto AeroDesign e o que ainda falta. É um juízo de valor, não uma
análise: nada aqui foi calculado.

**Referência:** relatórios de projeto completos de uma equipe, por área. Eles **não estão no git** e nenhum dado deles
entra aqui; servem só como lista do que um projeto completo cobre.

**Cuidado com estruturas:** os relatórios de referência têm valores inconsistentes nessa área. Servem como lista de
tópicos, não como validação nem como fonte de números.

**Legenda**
- ✅ coberto: tem módulo, teste e uso.
- 🟡 parcial: existe, mas falta parte do que a área faz.
- ❌ não coberto.
- ❓ a conferir: pode existir e não foi verificado.

Atualizar a cada branch que fechar um item.

---

## 1. Aerodinâmica

| Tópico | Estado | Onde / observação |
|---|---|---|
| Perfis: biblioteca, polares 2D por Reynolds, cache | ✅ | `aerosim/aero/sections.py`, `data/airfoils` |
| Escolha de perfil por pontuação/MTOW | 🟡 | sprint `design/airfoils.py` compara perfis; a pontuação ligada ao perfil fica no MDO |
| Asa finita: LLT, AVL, ASB, importar XFLR5 | ✅ | `aerosim/aero/*_solver.py`, `xflr5_import.py` |
| Comparação entre métodos (fonte/fidelidade) | ✅ | `aerosim/aero/service.py` |
| Asa por partições, perfil por seção | ✅ | modelo + tradutor |
| Polar do avião completo (CL, CD, Cm × α) | ✅ | aba Aerodinâmica |
| Arrasto por componente (fuselagem, trem, empenagens) | 🟡 | só a área de arrasto da fuselagem (`fus_CDS`); sem divisão por componente nem carenagem |
| Dispositivos de ponta de asa | ✅ | `aerosim/aero/tipdevices.py` |
| Downwash na cauda | 🟡 | empírico (ε0, dε/dα) na simulação; nas cargas sai das ferraduras da linha sustentadora |
| Efeito solo | 🟡 | `solo.mccormick`; falta o método de imagem e o efeito da mesa (só parte da asa sobre ela) |
| Esteira da hélice nas superfícies | 🟡 | `esteira.disco` (modifier, desligado por padrão); tubo reto, sem desvio |
| Distribuição ao longo da envergadura | ✅ | `core/src/loads/llt.zig` (para cargas) |
| Validação com ensaio (bancada / túnel) | ❌ | não há entrada de dados de ensaio para comparar |
| CFD | ❌ | a entrada padrão (`LoadResult`) já aceita uma malha de CFD; falta o leitor |

## 2. Desempenho

| Tópico | Estado | Onde / observação |
|---|---|---|
| Motor + hélice (tabela C_T, C_P) + bateria | ✅ | `core/src/physics/propulsion.zig` |
| Comparação de conjuntos motopropulsores | 🟡 | sprint "Motores"; sem banco de motores e hélices com limites de corrente |
| Perda de tração por corpos atrás da hélice | ❌ | só a esteira agindo nas superfícies; o efeito inverso (bloqueio) não existe |
| Ensaio dinâmico de hélice como entrada | 🟡 | tabela J, C_T, C_P aceita dados; não há rotina de ajuste de ensaio |
| Decolagem com pista limitada / mesa (6GDL) | ✅ | missão "só decolagem", `x_warning`, mesas |
| MTOW × altitude-densidade | ✅ | envelope por altitude |
| Tração/potência disponível × requerida | ✅ | Desempenho → Tração |
| Subida, voo nivelado, envelope | ✅ | Desempenho simples (Zig) |
| Curvas (raio mínimo, inclinação) | ✅ | missão "só curvas", desempenho |
| Planeio | ❓ | há gráficos de planeio; não conferido se há o envelope de planeio completo |
| Pouso (distância, trajetória) | 🟡 | `landingRun` no sizing; sem missão de pouso com trem e frenagem conferida |
| Consumo por fase de voo | 🟡 | bateria na missão; sem perfil de acelerador por fase vindo de ensaio |
| Interação xCG × MTOW | ✅ | sprint / Montagem |

## 3. Estabilidade e Controle

| Tópico | Estado | Onde / observação |
|---|---|---|
| Estática longitudinal (PN, ME) | ✅ | `aerosim/stability/static.py` |
| Diagrama tesoura | ✅ | `scissor.py` |
| Trimagem (profundor por V e n) | ✅ | `core` trim, nivelado e curva |
| Dimensionamento de EH e EV, superfícies de comando | ✅ | `stability/sizing.py`, `controls.py` |
| Direcional: vento de través no pouso | ❓ | `controls.py` tem critérios; o caso de vento de través não foi conferido |
| Lateral: taxa de rolamento (pb/2V) | ❓ | a conferir em `controls.py` |
| Dinâmica (modos, autovalores) | ✅ | linearização no núcleo + `dynamic.py` |
| Qualidades de voo (MIL-F-8785C) | ✅ | `criteria.py` |
| Efeito da flexão da asa (diedro elástico) em Clβ/Cnβ | ❌ | precisa de rigidez da asa (estruturas) |
| Comparação com voo sensoriado | ❌ | AeroDrive grava voos simulados; não há importação de log real |

## 4. Cargas

| Tópico | Estado | Onde / observação |
|---|---|---|
| Distribuição de sustentação por superfície num caso (V, n, rpm) | ✅ | `aerosim/aero/span_loads.py` (linha sustentadora, com/sem hélice) |
| Vista 3D e gráficos das cargas | ✅ | `LoadView`, `load_plots`; ainda fora da GUI principal |
| Diagrama V-n (manobra) | 🟡 | envelope tem V-n; sem os casos de carga tirados dele |
| Rajada (fatores por norma) | ❌ | só o evento "rajada" na missão |
| Casos de manobra (rolamento, cabrada/picada, leme) | ❌ | o 6GDL pode simular; falta montar os casos e extrair as cargas |
| Esforços internos: cortante, fletor, torsor ao longo da envergadura | ❌ | o próximo passo natural a partir da distribuição |
| Momentos de dobradiça | ❌ | |
| Cargas no solo (trem: pouso, taxiamento, uma roda) | ❌ | o trem existe na simulação; não há casos de carga |
| Convergência de malha das cargas | 🟡 | teste de convergência na linha sustentadora; sem estudo por avião |

## 5. Aeroelasticidade

| Tópico | Estado | Onde / observação |
|---|---|---|
| Centro elástico, rigidez torcional | ❌ | |
| Modos de vibração / GVT | ❌ | |
| Flutter | ❌ | |
| Divergência | ❌ | |
| Reversão de comando | ❌ | |

## 6. Estruturas

| Tópico | Estado | Onde / observação |
|---|---|---|
| Massas e inércias do avião | ✅ | modelo de massa, Montagem |
| Materiais (banco de propriedades) | ❌ | os números dos relatórios de referência **não** servem de fonte |
| Longarina (dimensionamento por flexão/deflexão) | ❌ | |
| Nervuras, fuselagem, tubo de cauda, trem | ❌ | |
| Margem de segurança por componente | ❌ | |
| FEM / ensaio estrutural | ❌ | fora do escopo do simulador; caberia como importação de resultado |

## 7. Elétrica e safety

| Tópico | Estado | Onde / observação |
|---|---|---|
| Bateria de propulsão (capacidade, C-rate, corrente de pico) | 🟡 | bateria no modelo; sem checagem de C-rate × pico |
| Servos (torque requerido por superfície) | ❌ | precisa dos momentos de dobradiça (cargas) |
| Bateria dos servos, cablagem (bitola) | ❌ | |
| FMEA | ❌ | documento, não simulação; fora do escopo |

## 8. Integração / MDO

| Tópico | Estado | Onde / observação |
|---|---|---|
| MDO (otimizador, pontuação) | ✅ | `core/src/sizing` (PSO), `design/mdo.py` |
| Variáveis do MDO (asa, cauda, CG, motor) | ✅ | |
| Estimativa de peso vazio | 🟡 | massas por componente; sem banco histórico de pesos |
| Volume de caixa / arranjo | ❓ | há restrições de caixa no design; arranjo 3D não |
| Tempo de montagem e desmontagem | ❌ | |
| Tempo de missão / circuito | 🟡 | missão por etapas; sem circuito real do local |
| Projeto do zero em etapas (sprint) | ✅ | `aerosim/design` |
| Checklist do avião | ✅ | `design/checklist.py` |

## 9. Além dos relatórios (só no simulador)

- Simulação 6GDL com piloto automático, sloshing, soltura de carga (LAPES), mesas e plataformas.
- AeroDrive: voo pilotado, gravação de voos, vídeo.
- Modifiers: métodos da literatura ligáveis por avião, sem mudar os arquivos antigos.
- Colisão do tubo da hélice com superfícies e objetos.

---

## Próximos itens (ordem sugerida)

1. Validar `feature/modifiers`: comparação bit a bit e suíte completa.
2. Cargas: definir os casos a partir do V-n (manobra e rajada) e tirar cortante, fletor e torsor.
   - A conta da distribuição é da aerodinâmica (`aero` + `core/loads`).
   - Os casos e os esforços são da área de cargas.
3. Aba Cargas na GUI, com a vista 3D.
4. Momentos de dobradiça → torque de servos (liga cargas a elétrica).
5. Trimagem com esteira e com a linha sustentadora.
6. Estruturas mínimas: longarina por flexão e deflexão. Os materiais vêm de fonte própria, nunca dos relatórios de
   referência.
7. Aeroelasticidade estática (diedro elástico, divergência) só depois de 6.

---

## Versionamento

**Regras**
- Nada direto na `main`. Cada trabalho tem a sua branch; a `main` só recebe por PR.
- Uma branch por tema: `feature/<tema>`, `fix/<tema>`, `docs/<tema>`.
- Relatórios e dados de terceiros nunca entram no git.
- Commit com mensagem no imperativo, curta, explicando o porquê no corpo.

**Situação atual das branches** (em relação à `main`)
- A pilha `feature/sprint` → `feature/gui` → `feature/aero` → `feature/modifiers` → `docs/tracking` ainda não foi para
  a `main`.
- `feature/sprint` está atrás da `main`, porque já teve um PR mesclado. As outras saíram dela, então seguem em cadeia.
- `feature/aircraft-drive` e `claude/ecstatic-gates-u3lpoi` não têm nada a mais que a `main`.

**Para melhorar**
1. Fechar a pilha em ordem, com um PR por branch, cada um com a sua validação (testes + comparação bit a bit).
2. Tag a cada PR mesclado (`v0.<n>.0`), com um `CHANGELOG.md` curto por versão.
3. Levar a comparação bit a bit (hoje um script fora do repositório) para `tools/` ou `tests/`, para rodar antes de
   cada PR.
4. Apagar as branches que já não têm nada a mais que a `main`, depois de confirmar.
