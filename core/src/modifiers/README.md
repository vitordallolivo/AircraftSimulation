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
| `types.zig` | `Modifier` (extern struct: `kind`, `enabled`, `surf_mask[2]`, `prop_mask`, `params[16]`) e os enums que dão nome aos números: `Ground` (método do efeito solo), `Kind` (tipo do efeito a mais) e `SlipstreamParam` (o que cada `params[k]` da esteira quer dizer) |
| `ground.zig` | métodos do efeito solo (`factor`, `mccormick`) |
| `slipstream.zig` | esteira por disco atuador (`diskInduced`, `axialAt`, `radiusAt`, `swirlRate`, `at`); `shape`/`TubeShape.tube` montam o tubo que contrai para `collision/` |
| `mod.zig` | entrada do módulo: `Env` (tração, torque, eixo e velocidade axial de cada motor no instante; `envFrom`), `induced` (soma dos efeitos a mais por painel, como média de uma grade `chord_samples × strip_samples` de pontos da faixa; quem está dentro do tubo é dito por `collision/`), `hits` / `hitsProp` (máscaras) |
| `README.md` | este arquivo |

## Números na ABI, nomes no núcleo

O Python escreve números (`Params.ground`, `Modifier.kind`, `params[k]`), porque a ABI só leva tipos C. Dentro do núcleo
cada número vira um enum, e o código decide por nome:

```zig
switch (m.kindOf()) {                        // Modifier.kind → Kind
    .slipstream_disk => slipstreamStrip(p, env, m, s),
    .none, _ => vec.zero,                    // vazio ou de outra versão: nada
}
const ax = m.slip(.axial_on) != 0;           // params[0], pelo nome
```

Número desconhecido (um arquivo de uma versão mais nova) cai no `_` do enum e é ignorado. Um tipo novo é um campo novo
no fim do enum, com o próximo número, e o mesmo número em `aerosim/model/modifiers.py` (`KINDS[...].core_id`).

As máscaras `surf_mask` e `prop_mask` são outra coisa: o bit $i$ é o painel (ou o motor) $i$, e zero quer dizer todos.

## Dois jeitos de entrar

| categoria | onde | padrão | exemplo |
|---|---|---|---|
| **solo**: método de um efeito que sempre existe; um por vez | `Params.ground` (número de `Ground`) | `Ground.mccormick` (o que o núcleo sempre fez) | `solo.mccormick`; sem nenhum na lista = desligado |
| **aditivo**: efeito a mais, somado em cada painel | `Params.mods[0..n_mod]` (`kind` = número de `Kind`) | nenhum (`n_mod = 0`: o laço nem roda) | `esteira.disco`, `tabela` (próxima etapa) |

## Compatibilidade (nada muda sem pedir)

- **`.json` antigo** (sem `modifiers`) abre com `default_modifiers()` = `[solo.mccormick]`, que é o
  comportamento de antes.
- **Exemplos de `data/aircraft`:** conferidos bit a bit antes e depois (coeficientes em α × β × V, resumo e
  registro completo da decolagem), sem diferença. Os testes `tests/model/test_modifiers.py` garantem que todos
  continuam abrindo com o padrão.
- **`.cfg` e planilha** não têm onde guardar modificadores: abrem com o padrão. Ao gravar nesses formatos
  com uma lista fora do padrão, a GUI avisa o que fica de fora (`modifiers.not_exported`).
- **AeroDrive** monta os `Params` dele com os padrões do Zig (`ground = Ground.mccormick`, `n_mod = 0`), então
  não muda. O leitor de JSON dele ignora a chave `modifiers`.
- **Tipo desconhecido** (arquivo de uma versão mais nova) fica guardado no `.json`, mas é ignorado, com
  aviso (`modifiers.problems`).

## Métodos e equações

### `solo.mccormick` (padrão)

Perto do chão, o arrasto induzido de cada painel horizontal é multiplicado por um fator que vai de 0 (no chão) a 1
(longe dele). Com $h$ a altura do painel acima do chão no passo ($h - z_{painel}$) e $b$ a envergadura de referência
(B. W. McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics*, Wiley; a mesma expressão em J. D. Anderson,
*Aircraft Performance and Design*, McGraw-Hill, que cita o McCormick; número da equação e página a conferir no PDF):

$$
\varphi = \frac{(16\,h/b)^2}{1 + (16\,h/b)^2}
\qquad
C_{D_i} \leftarrow \varphi\,C_{D_i}
$$

Altura menor que 1 cm é tratada como 1 cm (o painel não atravessa o chão). Testes: `ground.zig` (o valor da fórmula em
$h/b = 0{,}1$ e os limites 0 e 1); `tests/model/test_modifiers.py` (desligar muda a decolagem).

### `esteira.disco` (aditivo, desligado por padrão)

Por motor, com a tração $T$ e o torque $Q$ do instante, carga uniforme num disco de raio $R$ e área $A = \pi R^2$, e
$V$ a velocidade axial através do disco.

**1. Velocidade induzida no disco**, pela teoria do momento de Rankine–Froude (McCormick, *Aerodynamics, Aeronautics,
and Flight Mechanics*; Glauert, "Airplane Propellers", em Durand, *Aerodynamic Theory* IV, 1935):

$$
T = 2\,\rho\,A\,w_0\,(V + w_0)
\quad\Rightarrow\quad
w_0 = -\frac{V}{2} + \sqrt{\frac{V^2}{4} + \frac{T}{2\rho A}}
$$

**2. Desenvolvimento ao longo do eixo.** O disco com carga uniforme é um cilindro de vórtices semi-infinito; com $x$
medido a partir do disco, positivo para trás (McCormick, *Aerodynamics of V/STOL Flight*; Veldhuis, ICAS 2004 e tese TU
Delft 2005):

$$
w(x) = w_0\left(1 + \frac{x}{\sqrt{x^2 + R^2}}\right)
\qquad
w(0) = w_0,\quad w(\infty) = 2\,w_0,\quad w(-\infty) = 0
$$

**3. Contração do tubo**, por continuidade:

$$
(V + w(x))\,R(x)^2 = (V + w_0)\,R^2
$$

**4. Giro.** O fluxo de momento angular que atravessa o disco é o torque (balanço de Glauert). Com rotação de corpo
rígido $v_t = \Omega\,r$ (hipótese desta implementação) e conservando o momento angular no tubo que contrai:

$$
Q = \int_A \rho\,(V + w_0)\,v_t\,r\,dA
\quad\Rightarrow\quad
\Omega_0 = \frac{2\,Q}{\pi\,\rho\,(V + w_0)\,R^4}
\qquad
\Omega(x) = \Omega_0\left(\frac{R}{R(x)}\right)^2
$$

O giro tem o sentido da rotação da hélice (só atrás do disco).

**5. No painel.** A velocidade que o painel vê soma a axial ao longo do eixo de tração $\hat e_T$ e tira o giro, com os
ganhos de calibração (`SlipstreamParam.axial_gain`, `swirl_gain`; 1 é a teoria), em média nos pontos da faixa dentro do
tubo (`collision/`). N motores somam por superposição:

$$
\Delta\vec v = k_{ax}\,w\,\hat e_T - k_{giro}\,\vec v_{giro}
$$

Equações e páginas a conferir nos PDFs. Testes: `slipstream.zig` (a teoria do momento; o caso estático; $w(0) = w_0$ e
$w(\infty) = 2w_0$; a contração; a integral do momento angular igual a $Q$; fora do tubo nada; o sentido inverte o giro)
e `tests/model/test_slipstream.py` (tração zero é idêntico bit a bit; o giro sozinho espelha $C_l$ ao inverter o sentido;
bimotor simétrico com sentidos opostos dá $C_l = C_n = C_Y = 0$; superposição; máscara de motores; a sonda bate com a
teoria do momento).

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
- esteiras que se cruzam somam (a superposição deixa de ser exata);
- a parte da faixa fora do tubo (acima ou abaixo da linha de tração, ou fora da envergadura do tubo) não recebe nada: a
  faixa é amostrada numa grade e só os pontos dentro do tubo (`collision.Tube.contains`) somam.

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

Pelo Python, sem a linha de comando:

```python
from aerosim.backend.zig import ZigBackend
from aerosim.model.modifiers import Modifier, describe
from aerosim.model.templates import conventional

ac = conventional()
print(describe(ac))                                  # ["efeito solo: McCormick (padrão)"]
ac.modifiers.append(Modifier(kind="esteira.disco"))  # liga a esteira da hélice
phi = ZigBackend().probe_ground(1, [0.1, 0.5, 2.0], 2.2)   # φ de McCormick (Ground.mccormick = 1) em três alturas
print(describe(ac), phi)
```

Testes do módulo: `zig build test-physics` (inclui `modifiers/`), `pytest tests/model/test_modifiers.py`.

## Como adicionar um modificador

1. **Fonte primeiro:** obra, equação, página. Sem isso não entra.
2. Em `types.zig`: um campo novo em `Kind` (aditivo) ou em `Ground` (solo), com o próximo número, e um enum com o que
   cada `params[k]` quer dizer (como `SlipstreamParam`).
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
