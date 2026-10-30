# Aircraft Simulation

O Aircraft Simulation nasceu para preencher uma lacuna clássica na engenharia aeronáutica: a distância entre o projeto conceitual em planilhas/papel e a validação em um simulador de voo real. É uma ferramenta completa que une o dimensionamento paramétrico avançado, a análise aerodinâmica e de estabilidade, e uma simulação de voo 3D interativa de alta performance.

Seja para projetar uma aeronave do zero (como competições de Aerodesign, VANTs ou protótipos experimentais), otimizar o peso máximo de decolagem (MTOW) sob restrições severas de pista, ou testar o comportamento dinâmico em tempo real, este ecossistema coloca todo o controle na suas mãos de forma modular.

![Projeto do zero — perfil: S1223 e perfis de cauda](docs/img/estudo_perfil.png)

![Projeto do zero — asa S1223](docs/img/estudo_asa.png)

![Projeto do zero — empenagem com EH MH 113 invertido](docs/img/estudo_empenagem.png)

![Projeto do zero — motores e distribuição de massa](docs/img/estudo_motores.png)

![Estudo e ponto de projeto — inclinação do motor em Joinville e São José dos Campos, conferido no 6GDL](docs/img/estudo_ponto_de_projeto_graficos.png)

![Configuração](docs/img/gui_configuracao.png)

![Missão: trajetória 3D por etapa](docs/img/gui_missao_3d.png)

![Missão: plano XY com os eventos](docs/img/gui_missao_xy.png)

![Desempenho: envelope de voo](docs/img/gui_desempenho.png)

![AeroDrive: voo em perseguição com minimapa e vento](aerodrive/docs/img/voo_cruzeiro.png)

---


O programa é divido em dois modos, o aerodrive e o aerosim, o aerodrive é uma simulação de tempo real que permite controlar a aeronave que você acaba de projetar e o
aerosim é justamente o local onde você irá projetar. Desenvolvido em duas linguagens de programação em python para as interfaces e zig para calculos mais proximos de tempo real
possível.


## Instalar

Precisa de **Git** e **Python 3.10 ou mais novo** (testado no 3.11). Basta então clonar o repositório e instalar os requerimentos.



```sh
git clone https://github.com/vitordallolivo/AircraftSimulation.git
cd AircraftSimulation

python -m venv .venv
.venv\Scripts\activate                 

pip install -r requirements.txt
pip install -r requirements-aero.txt   # opcional: lltdrek e AeroSandbox (comparação na aba Aerodinâmica)
```

## Rodar

Os programas em Zig compilam e abrem a partir da raiz, cada um pelo nome:

```sh
python -m ziglang build aerodrive          # o simulador
python -m ziglang build aerosim            # a interface do aerosim em Zig
python -m ziglang build aeroopt            # a interface do aeroopt em Zig
python -m ziglang build                    # compila os três
python -m ziglang build test               # testes do núcleo, das interfaces e do AeroDrive
```


Já para o aerosim você pode:

```sh
python -m aerosim.gui                                              # volta ao último projeto (ou Montagem vazia)
python -m aerosim.gui ~/sprint                                     # abre a pasta da sprint (um arquivo por asa)
python -m aerosim.gui data/sprint/projeto_s1223.json               # projeto antigo: abre e grava em <meus aviões>/sprint/
python -m aerosim.gui data/aircraft/Asa_voadora.json               # abre um avião (.json, .cfg ou .xlsx)
```

- **Projeto da sprint numa pasta** (linha de comando, **Projeto da sprint → Abrir pasta da sprint…** ou
  arrastar a pasta para a janela): um arquivo por asa (a asa + as superfícies feitas para ela + os aviões) e
  o `sprint.json` com o resto. Volta de onde parou — etapas (perfis, asas, conjuntos, aviões,
  estudos), os aviões abertos na Montagem e a aba em que estava; mostra o que está guardado. Sem avião
  guardado no projeto, a **Montagem começa vazia** e o avião aparece no 3D peça por peça
  (**+ Asa, + EH, + EV, + Motor, + Tubo, + Tanque**); a massa vem das peças.
- **Tubos e caudas sem tipo pronto:** quantos tubos quiser, cada um com início (x, y, z), comprimento,
  inclinação e abertura (tubo duplo = dois tubos em y = ±d); cada superfície tem **presa em**: solta, na
  ponta de um tubo ou na ponta de outra superfície (cauda em T, winglet). Cauda em V = EH com diedro.

- **Perfil por seção:** na tabela de seções de cada superfície, a coluna **perfil** ('= superfície', um NACA
  digitado, um perfil já usado no avião ou um `.dat`); entre seções as propriedades do perfil são
  interpoladas e cada faixa vai para o núcleo com as suas.
- **Mistura de comandos:** o tipo do comando é só o nome; o que ele faz é a linha **arfagem, rolagem,
  guinada** (elevon = 1, 1, 0; ruddervator = 1, 0, 1; flaperon = rolagem com deflexão fixa; qualquer
  outra combinação, com ganhos fracionários).
- **Eixo de motor móvel (tilt-rotor):** cada motor tem **eixo móvel: faixa**; a inclinação vai de
  'inclinação' até 'inclinação + faixa' pelo comando de inclinação (0 a 1) do núcleo.

![Montagem vazia](docs/img/montagem_vazia.png)
![Tubo duplo inclinado, duas EV e EH em T, montados na interface](docs/img/montagem_tubo_duplo_cauda_em_T.png)
![S1223 na raiz, NACA 0012 na ponta; aileron com mistura de arfagem (elevon 0,5 : 1)](docs/img/montagem_perfil_por_secao_mistura.png)

- **💾 Salvar avião / 📂 Meus aviões** guardam seus aviões (pasta `~/aerosim_aeronaves`, ou a variável
  `AEROSIM_PROJETOS`). Exemplos prontos em `data/aircraft/`.
- Em cada aba: preencha os campos (o **ⓘ** explica cada um), clique em **▶ Rodar**; os gráficos
  atualizam enquanto roda; no fim vêm o **diagnóstico** (clique numa linha para ver o porquê e o que
  mudar) e a tabela de resultados; **Exportar** grava `.xlsx` ou `.csv`.
- **Projeto do zero** (subabas de Aerodinâmica, Estabilidade e Desempenho): **Perfis** (candidatos e polar
  2D: NACA, .dat, só parâmetros ou polar do XFLR5) → **Projetar** (a asa: planta, linha sustentadora, onde estola,
  incidência pelo ângulo de cruzeiro) → **Empenagem e comandos** (cauda por volume, tubo, CG na margem
  pedida, faixa de CG, rotação na decolagem) → **Motores e montagem** (motores, distribuição de massa com PV
  e carga paga só como opções — tem LAPES? quantas; tem líquido? quantos tanques; os kg se decidem na Montagem —, bateria no ponto do CG, trem, desempenho e o MTOW pela pista) →
  **Mandar para a Montagem** ou **Usar em Desempenho** (sem exigir que decole: se não decolar, vai com o aviso); **Estudo e ponto de projeto** (Desempenho) acopla as áreas e varre uma variável (ex.: inclinação do motor) nas altitudes-densidade pedidas (exemplos prontos: `data/aircraft/S1223_*.json` e `data/sprint/projeto_s1223.json`). Cada etapa guarda candidatos com nome; o programa compara,
  não escolhe. **Condições e restrições…** (em toda etapa): condições de partida (massa estimada, velocidade, AD,
  atrito), **restrições** que se ligam e desligam com operador ≤ ≥ = (envergadura, área, estol, corrida — decolar
  em 3 m é só `corrida ≤ 3` —, potência, número de superfícies e de motores, EE, massa de líquido e de LAPES,
  subida...), **variáveis** (fixo, variável com mín./máx. ou lista de opções, calculado) e regras. PV, CP, EE e
  MTOW são saídas.

  ![Restrições](docs/img/condicoes_restricoes.png)
  ![Variáveis](docs/img/variaveis.png)

  Detalhes em [aerosim/design](aerosim/design/README.md).

- **Dimensionamento inicial**: O aerosim conta com um módulo capaz de com base nas restrições usar as teorias de `initial sizing` definir
  as dimensões de asa

  Todo e qualquer projeto tem seus limites/restrições para isso temos uma aba somente com a capacidade de escolher as restrições, ligando ou
  as desligando as tabelas de cada área de projeto são atualizados, bem como permite otimizar de uma forma mais consistente a aeronave com base nisso.

  ![Envelope completo](docs/img/mdo2_envelope.png)
  ![Diagrama de restrições do indivíduo](docs/img/mdo2_diagrama.png)
  ![Histórico: o enxame da iteração 3](docs/img/mdo2_historico.png)
  ![Seletor de perfis](docs/img/seletor_perfis.png)
- **Montagem** (última aba): componentes, 3D editável, ambiente (altitude-densidade, vento) e envelope
  de voo (ângulo de cruzeiro, fator de carga). As subabas "Avião montado", Analisar (Aerodinâmica) e a
  Missão (dentro de Desempenho, junto com Tração) mostram o avião atual em 3D acima dos gráficos.
- **Vários aviões:** **Arquivo → Abrir ao lado** ou **＋ variante** abre mais um; ◀ ▶ troca, e todas
  as abas rodam o escolhido.



Instalação e comandos em [aerodrive/README.md](aerodrive/README.md).

### Pelo Python (sem GUI)

Rode da raiz do repositório:

```python
from aerosim.manager import SimulationManager
from aerosim.data import load_aircraft

m = SimulationManager()
ac = load_aircraft("data/aircraft/Convencional_original.json")

r = m.run("mission", ac, {"mode": "só decolagem"})   # decolagem otimizada para x_warning e z_warning
print(r.status, r.summary["n_dec"])                  # COMPLETED 51.4

r = m.run("mission", ac)                             # missão inteira, etapa por etapa
print(r.log["t"][-1], r.summary["energia_Wh"])
for c in r.checks:                                   # o diagnóstico
    print(c.status, c.item, c.value)
```

Simulações: `sizing`, `mission`, `performance`, `thrust`, `aerodynamics`, `stability` (mais detalhes em
[aerosim/manager/README.md](aerosim/manager/README.md)).

### Testes

```sh
python -m pytest                       # tudo (~3 min)
python -m pytest tests/manager         # uma parte
(cd core && python -m ziglang build test)        # testes do núcleo em Zig
(cd aerodrive && python -m ziglang build test)   # testes e fuzzing do aerodrive
```


---

## Problemas comuns

| sintoma | solução |
|---|---|
| `ImportError: libEGL.so.1` / `could not load the Qt platform plugin "xcb"` | instale as bibliotecas do passo 1 |
| `ModuleNotFoundError: No module named 'aerosim'` | rode da raiz do repositório (ou `export PYTHONPATH=$PWD`) |
| `FileNotFoundError: zig` | `pip install ziglang==0.16.0` ou ponha o `zig` 0.16 no PATH |
| erro de compilação do Zig | use exatamente o Zig **0.16** |
| tela cortada em notebook / Wayland | as divisórias entre as colunas são largas: arraste para alargar o painel |
| sem 3D numa máquina remota | o 3D precisa de OpenGL; sem tela use `QT_QPA_PLATFORM=offscreen` (as simulações funcionam) |
