# AircraftSimulation — como trabalhar neste repositório

Leia isto inteiro no começo de cada sessão. Depois, para achar qualquer coisa, abra **`docs/MAP.md`**: é o mapa do
código, gerado a partir dele (`python tools/codemap.py`). O que falta fazer e em que ordem fica em
**`docs/TRACKING.md`**.

---

## 1. Objetivo

Ferramenta para **dimensionar uma aeronave** (AeroDesign, VANT, protótipo) e voar o resultado.

- **`aerosim`**: onde se projeta. É a GUI em PyQt6, com dimensionamento, aerodinâmica, desempenho, estabilidade,
  missão 6GDL e cargas.
- **`aerodrive`**: simulação em tempo real (Zig + raylib) para pilotar o avião projetado.
- **`core`**: núcleo físico em Zig, compartilhado pelos dois. Memória estática, sem alocação em tempo de execução.

**Fora do escopo:**
- A escolha de bateria, servos e cabos é da área de elétrica. A simulação só mostra o que já calcula (corrente
  média, de pico e consumo).
- Torres de menor prioridade (estão em `docs/TRACKING.md`): VTOL/tailsitter, CFD 3D, CAD, controle não linear.

## 2. Conceitos

| Conceito | O que é | Onde |
|---|---|---|
| Configuração (`Aircraft`) | O avião como o usuário descreve: superfícies, motores, massas, missão | `aerosim/model/aircraft.py` |
| Modelo universal | O avião derivado **uma vez**: painéis, estações, CMA, massas. Todo solver recebe isso | `aerosim/model/universal.py` (`build_model`) |
| Tradutor | Converte o modelo universal para o formato de um solver e volta em coeficientes universais | `aerosim/backend/zig/translator.py`, `aerosim/aero/*_solver.py` |
| Interfaces | Contratos entre as camadas (só classes abstratas e tipos) | `aerosim/interfaces/` |
| Simulação (aba) | Uma `ISimulation` por análise: campos, gráficos, `run` → `SimResult` com `checks` | `aerosim/manager/simulations/` |
| Modifier | Método da literatura ligável por avião (efeito solo, esteira), desligado por padrão | `core/src/modifiers/`, `aerosim/model/modifiers.py` |
| `LoadResult` | Entrada padrão das análises de carga: qualquer método (núcleo, VLM, CFD) entrega isso e os gráficos e o 3D leem | `aerosim/interfaces/loads.py` |
| ABI do núcleo | Funções `export fn` de `core/src/root.zig`, chamadas por ctypes; esquema com hash conferido ao carregar | `core/src/root.zig`, `aerosim/backend/zig/` |

**Camadas:** GUI → Simulation Manager → interface → backend/núcleo. **Aircraft Data** (`aerosim/data`) carrega e grava
as configurações.

## 3. Decisões de projeto (regras; não quebrar)

1. **Sempre uma interface entre camadas.**
   - Quem usa uma camada depende de `aerosim/interfaces`, nunca do módulo concreto.
   - Um método novo (solver, núcleo, fonte de dados) **implementa a interface**. Quem consome não muda.
2. **A GUI não faz conta.**
   - A GUI chama o manager.
   - O manager chama o backend.
   - A conta pesada fica no Zig sempre que der; o Python orquestra e traduz.
3. **O modelo universal é construído uma vez.**
   - Formatos nativos (SimSpec do núcleo, Wing do lltdrek, Airplane do ASB) só aparecem nos tradutores.
   - `tests/test_architecture.py` fiscaliza isso.
4. **Fórmula só com fonte.** Obra, equação e página no comentário ou no README. Sem confirmação no PDF, escrever
   "a conferir no PDF". Nada de fórmula inventada.
5. **Física nova não muda o que existe.**
   - Ela entra como modifier ou como método novo, **desligada por padrão**.
   - Os `.cfg`/`.json` antigos carregam iguais.
   - A simulação e o AeroDrive ficam bit a bit iguais; a regressão em `tools/checks` confere.
6. **Nenhuma dependência obrigatória de detalhe.** Um módulo não exige um componente opcional (ex.: dados de
   bateria). Sem o dado, a análise que precisa dele é pulada, e o resto roda igual.
7. **Dado é dado.**
   - Nunca gerar nem editar nada dentro de `data/`.
   - Relatórios e dados de terceiros nunca entram no git. As planilhas e os PDFs do usuário ficam fora do repositório.
   - Diagramas não vão para o git.
8. **Teste simples de rodar.**
   - Cada funcionalidade tem teste em `tests/<área>`.
   - Quando faz sentido, uma ferramenta de linha de comando em `tools/` que imprime e plota.
   - Sempre que possível, validar contra a literatura, com o número esperado escrito no teste.
9. **Textos em português**: mensagens, gráficos, documentação, commits. Os comentários seguem o estilo do arquivo.

## 4. Como trabalhar com o dono do repositório

- **Uma tarefa por vez.**
  1. Terminar a tarefa.
  2. Rodar os checks.
  3. Abrir o PR.
  4. **Parar e esperar o review.**

  Não abrir várias frentes nem começar a próxima tarefa por conta própria.
- **Ideia nova vai primeiro para o plano.** Quando o pedido é "pensar", não programar: mostrar o plano, com as fontes,
  e esperar o ok.
- Não inventar escopo: o que não foi pedido vira proposta, não código.
- Rodadas longas (suíte completa, regressão) avisando antes; não rodar várias ao mesmo tempo na mesma árvore.

## 5. Git e versões

- **Branch única de desenvolvimento: `0.2_dev`.** Não criar outras branches. Nunca mexer direto na `main`.
- **Fluxo de uma tarefa:**
  1. Mesclar a `main` na `0.2_dev`.
  2. `python tools/checks/run.py --tudo`.
  3. `python tools/codemap.py`.
  4. Atualizar `docs/TRACKING.md` e `CHANGELOG.md`.
  5. Abrir o PR `0.2_dev` → `main` e parar.
- **Versão:**
  - A `main` está em `v0.2.0`.
  - Cada tarefa mesclada sobe o último número (`0.2.1`, `0.2.2`…).
  - A lista inteira do tracking feita vira `0.3.0`.
  - Não existe promessa de 1.0: nada vira release sem o dono testar cada componente.
- **Commits** terminam com as linhas de atribuição pedidas pela sessão. Sem identificador de modelo em commit, código
  ou PR.

## 6. Onde estão as métricas

| O quê | Onde |
|---|---|
| Progresso da lista (itens com ✅ na GUI), quadro de tarefas com dependências | `docs/TRACKING.md` → "Progresso", "Quadro" |
| Histórico por versão | `CHANGELOG.md` |
| Regressão: núcleo, AeroDrive, exemplos bit a bit contra a `main`, testes por área | `python tools/checks/run.py` (`--tudo`, `--lista`, `--relatorio x.md`) |
| Contagem de testes por área, ABI do núcleo, funções públicas | `docs/MAP.md` |
| Tempo (benchmarks) | `pytest -m bench -s`; `core/src/bench.zig` (export `aerosim_bench_*`) |

## 7. Comandos

```sh
python tools/codemap.py                          # refaz docs/MAP.md (e --check para conferir)
python tools/checks/run.py                       # checks rápidos; --tudo inclui GUI, design e manager
cd core && python -m ziglang build test          # testes do núcleo (test-math, test-physics, test-sim...)
cd aerodrive && python -m ziglang build test     # testes do AeroDrive; build run abre o jogo
QT_QPA_PLATFORM=offscreen python -m pytest -q tests/<área>
python -m aerosim.gui [arquivo ou pasta]         # a GUI
xvfb-run -a python tools/load_view.py <avião> --png x.png   # imagem da vista 3D sem tela
```

O backend Python compila o núcleo sozinho quando o código Zig muda (`aerosim/backend/zig/backend.py`, `build`).

## 8. Como achar as coisas

1. `docs/MAP.md`: todo arquivo, com a primeira linha da documentação e os nomes públicos (`nome:linha`), mais a
   lista dos exports da ABI.
2. O `README.md` da pasta: como chamar e como funciona.
3. `rg` (ripgrep) para o resto.

Depois de criar, mover ou renomear arquivos ou funções públicas, rodar `python tools/codemap.py`. O check
`mapa do código em dia` acusa se ficou desatualizado.
