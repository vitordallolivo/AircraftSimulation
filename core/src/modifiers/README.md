# core/src/modifiers — modificadores

Metodologias da literatura que mudam a aerodinâmica do **avião inteiro** sem mexer no resto do núcleo.
Hoje: efeito solo e esteira da hélice. Depois: tabelas de correção (VSPAERO, CFD, túnel).

- **O Python só monta dados.** A lista `Aircraft.modifiers` (`aerosim/model/modifiers.py`) vai pelo
  tradutor (`aerosim/backend/zig/translator.py`) para os campos `ground`, `n_mod` e `mods` de `Params`.
- **Quem calcula é este módulo,** com um `switch` por tipo conhecido, código estático e sem alocação.
- **Toda fórmula tem a fonte** no comentário do código e na tabela de referências abaixo. Nada sem referência.

```
aerosim/model/modifiers.py   Modifier(kind, enabled, name, params, targets, props)    ← GUI (Montagem) só edita
        │  backend/zig/translator.py: modifiers.native(...)
        ▼
Params.ground   (método do efeito solo: um por vez)
Params.n_mod / Params.mods[max_mods]   (efeitos a mais: vazios por padrão)
        │
        ▼
physics/aero.zig, em cada painel i (centro r):
    v_i  = V_ar + ω × r  [+ Σ modifiers.induced(p, env, i, r)   só se n_mod > 0]
    C_Di ← modifiers.ground.factor(p.ground, h_i, b) · C_Di      (painéis não verticais)
```

## Arquivos

| arquivo | o que tem |
|---|---|
| `types.zig` | `Modifier` (extern struct: `kind`, `enabled`, `surf_mask[2]`, `prop_mask`, `params[16]`), constantes `ground_*` e `kind_*` |
| `ground.zig` | métodos do efeito solo (`factor`, `mccormick`) |
| `slipstream.zig` | esteira por disco atuador (`diskInduced`, `axialAt`, `radiusAt`, `swirlRate`, `at`) |
| `mod.zig` | entrada do módulo: `Env` (tração, torque, eixo e velocidade axial de cada motor no instante; `envFrom`), `induced` (soma dos efeitos a mais por painel, como média de `strip_samples` pontos ao longo da envergadura da faixa), `hits` / `hitsProp` (máscaras) |
| `README.md` | este arquivo |

## Dois jeitos de entrar

| categoria | onde | padrão | exemplo |
|---|---|---|---|
| **solo**: método de um efeito que sempre existe; um por vez | `Params.ground` | `ground_mccormick` (o que o núcleo sempre fez) | `solo.mccormick`; sem nenhum na lista = desligado |
| **aditivo**: efeito a mais, somado em cada painel | `Params.mods[0..n_mod]` | nenhum (`n_mod = 0`: o laço nem roda) | `esteira.disco`, `tabela` (próxima etapa) |

## Compatibilidade (nada muda sem pedir)

- **`.json` antigo** (sem `modifiers`) abre com `default_modifiers()` = `[solo.mccormick]`, que é o
  comportamento de antes.
- **Exemplos de `data/aircraft`:** conferidos bit a bit antes e depois desta mudança (coeficientes em
  α × β × V, resumo e registro completo da decolagem, 9 arquivos): **0 diferenças**. Os testes
  `tests/model/test_modifiers.py` garantem que todos continuam abrindo com o padrão.
- **`.cfg` e planilha** não têm onde guardar modificadores: abrem com o padrão. Ao gravar nesses formatos
  com uma lista fora do padrão, a GUI avisa o que fica de fora (`modifiers.not_exported`).
- **AeroDrive** monta os `Params` dele com os padrões do Zig (`ground = mccormick`, `n_mod = 0`), então
  não muda. O leitor de JSON dele ignora a chave `modifiers`. Compila e passa os 91 testes.
- **Tipo desconhecido** (arquivo de uma versão mais nova) fica guardado no `.json`, mas é ignorado, com
  aviso (`modifiers.problems`).

## Métodos e referências

| tipo | fórmula | fonte | testes |
|---|---|---|---|
| `solo.mccormick` (padrão) | φ = (16 h/b)² / (1 + (16 h/b)²); C_Di ← φ C_Di em cada painel horizontal; h = altura do painel acima do chão no passo (`h − z_painel`), b = envergadura de referência; h ≤ 1 cm vira 1 cm | B. W. McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics* (Wiley). A mesma expressão em J. D. Anderson, *Aircraft Performance and Design* (McGraw-Hill), que cita o McCormick. **Número da equação e página: a conferir no PDF** | `ground.zig` (h/b = 0,1 → 2,56/3,56; limites 0 e 1); `tests/model/test_modifiers.py` (desligar muda a decolagem) |

| `esteira.disco` (aditivo, desligado por padrão) | por motor, com a tração T e o torque Q do instante: (1) w0 da teoria do momento, T = 2ρA w0 (V + w0); (2) w(x) = w0 (1 + x/√(x² + R²)) ao longo do eixo (x > 0 atrás do disco; à frente também, sem giro); (3) contração (V + w) R² = const; (4) giro de corpo rígido com fluxo de momento angular = Q: Ω0 = 2Q/(π ρ (V + w0) R⁴), Ω(x) = Ω0 (R/R(x))², no sentido da hélice. O painel soma `ganho_axial·w·eT − ganho_giro·v_giro`, média em 16 pontos ao longo da faixa (faixa só em parte dentro do tubo). N motores: superposição | (1) Rankine–Froude, em McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics*, e Glauert, "Airplane Propellers", em Durand, *Aerodynamic Theory* IV (1935); (2) disco atuador com carga uniforme (cilindro de vórtices semi-infinito), em McCormick, *Aerodynamics of V/STOL Flight*, e Veldhuis (ICAS 2004; tese TU Delft 2005); (3) continuidade; (4) balanço de momento angular de Glauert, com a **hipótese de corpo rígido desta implementação**. **Equações e páginas: a conferir nos PDFs** | `slipstream.zig` (T = 2ρA w0(V+w0); estático; w(0) = w0, w(∞) = 2w0; contração; ∫ρ(V+w0) v_t r dA = Q; fora do tubo nada; sentido inverte o giro); `tests/model/test_slipstream.py` (tração zero = idêntico bit a bit; giro sozinho espelha C_l ao inverter o sentido; bimotor simétrico com sentidos opostos: C_l = C_n = C_Y = 0; superposição dos dois motores; máscara de motores; sonda = teoria do momento) |

### Limites conhecidos do `solo.mccormick`

São as razões para ter outros métodos depois:

- só reduz o arrasto induzido: não aumenta C_Lα e não muda o downwash na cauda perto do chão;
- a altura do painel usa o z dele no corpo, sem girar pela arfagem e pelo rolamento;
- usa o `b` de referência até para a EH.

### Limites conhecidos do `esteira.disco`

- velocidade axial do eixo aplicada igual em toda a seção do tubo (perfil "chapéu"; Conway 1995 dá a carga
  não uniforme);
- o tubo segue o eixo do motor: não é desviado pelo α nem pela asa;
- sem interação hélice → hélice (tandem: a de trás não vê a esteira da da frente no J dela) e asa → hélice
  (upwash, força normal na hélice);
- só onde há tração do instante: na simulação (decolagem, missão) sim; trimagem, linearização e envelope
  ainda chamam a aerodinâmica sem motores (`Env.none`), então não veem a esteira;
- esteiras que se cruzam somam (a superposição deixa de ser exata).

### Próximos tipos (planejados; só entram com a fonte conferida)

| tipo | ideia | fontes a conferir |
|---|---|---|
| `solo.imagem` (categoria solo) | método da imagem: sistema de vórtices espelhado abaixo do chão; mexe em C_L, C_Di e no downwash da cauda, e usa a altura de cada painel com a atitude | Katz e Plotkin, *Low-Speed Aerodynamics*; Phillips e Hunsaker, *Lift and Drag of Wings in Ground Effect* (J. Aircraft, 2013) |
| `esteira.conway` (aditivo) | o mesmo com carga não uniforme no disco | Conway (J. Fluid Mech., 1995) |
| `tabela` (aditivo) | correção por painel (Δα, fator de pressão dinâmica, ΔC_L) em função de α, β, J e comandos, gerada fora da simulação (VSPAERO, CFD, túnel); o núcleo só interpola | a fonte é a de quem gerou a tabela (fica guardada no modificador) |

## Como testar sem GUI

```
python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02                  # CSV na tela
python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02 --png solo.png   # e o gráfico
python tools/modcheck.py data/aircraft/Convencional_original.json --sem-solo
python tools/probe.py esteira --T 30 --Q 1.2 --D 0.38 --V 10 --x=-0.3:1.5:0.02 --png esteira.png   # ao longo do eixo
python tools/probe.py esteira --T 30 --Q 1.2 --D 0.38 --V 10 --x 0.5 --r 0:0.25:0.005               # corte radial
python tools/modcheck.py data/aircraft/Convencional_original.json --com esteira.disco
```

- O `probe` chama as funções de sonda do núcleo, sem simulação (`aerosim_probe_ground` e
  `aerosim_probe_slipstream` em `root.zig`; `ZigBackend.probe_ground`/`probe_slipstream` no Python). Nenhuma
  conta é feita em Python.
- `aerosim_aero_coeffs_thrust` (sessão: `aero_coeffs_thrust(V, α, β, T[], Q[])`) dá os coeficientes do avião com a
  tração e o torque de cada motor, para estudar a esteira sem simular.
- `aerosim_panel_states` (sessão: `panel_states(V, α, β, T[], Q[])`) dá o estado de cada faixa (`PanelState`: centro,
  área, corda, grupo, α e velocidade locais, C_L, C_D, sustentação e arrasto em N), saído de `aero.computeTrace`, o
  mesmo laço da simulação. Com ele, `tools/span_load.py` desenha a carga ao longo da envergadura (y em metros) da
  asa e da EH com e sem um modificador:

```
python tools/span_load.py data/aircraft/Bimotor_convencional_tubo_cauda_em_V.json --com esteira.disco --png carga.png
```
- O `modcheck` roda a decolagem com os modificadores do avião, sem cada um e, com `--sem-solo`, sem efeito
  solo, e mostra a diferença.

Exemplo, com o `Convencional_original.json`:

| caso | decolou em (m) | saiu do chão em (m) |
|---|---|---|
| efeito solo de McCormick (padrão) | 51,381 | 39,679 |
| sem efeito solo | 51,935 (+0,554) | 40,625 (+0,946) |
| efeito solo + esteira | 49,497 (−1,884) | 37,404 (−2,275) |

Testes do módulo: `zig build test-physics` (inclui `modifiers/`), `pytest tests/model/test_modifiers.py`.

## Como adicionar um modificador

1. **Fonte primeiro:** obra, equação, página. Sem isso não entra.
2. Em `types.zig`: o `kind_*` (aditivo) ou `ground_*` (solo) e o que cada `params[k]` quer dizer.
3. Em `mod.zig` (aditivo, um caso no `switch` de `induced`) ou em `ground.zig` (solo, um caso em `factor`):
   a fórmula, com a referência no comentário. Teste Zig que reproduz um número publicado.
4. Uma sonda em `root.zig` (`aerosim_probe_*`) e o subcomando em `tools/probe.py`.
5. Em `aerosim/model/modifiers.py`: a entrada em `KINDS` (título, categoria, `core_id`, referência,
   parâmetros com unidade).
6. Testes de invariância (desligado = sem efeito; sentido invertido espelha; simetria; superposição).
7. Uma linha na tabela "Métodos e referências" acima.

## Outras mudanças no núcleo que vieram junto

- **Propulsão antes da aerodinâmica** (`sim/dynamics.zig`): a tração e o torque do instante vão para os
  modificadores em `Env`. As duas contas são independentes, então o resultado não muda (conferido bit a
  bit).
- **`aero.computeEnv`:** `aero.compute` com o `Env`. O `compute` antigo continua e chama este com
  `Env.none`; trimagem, linearização, envelope e coeficientes seguem por ele.
- **ABI:**
  - `Modifier` entra no esquema e `limit mods` no cabeçalho;
  - o hash FNV-1a do esquema (`aerosim_schema_hash`) já confere que o Python e a biblioteca falam do
    mesmo layout;
  - biblioteca de uma versão anterior recompila sozinha.
- **`lib.zig`** exporta `modifiers` para programas Zig (AeroDrive) que quiserem usar.
