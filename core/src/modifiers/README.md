# core/src/modifiers — modificadores

Metodologias da literatura que mudam a aerodinâmica do **avião inteiro** sem mexer no resto do núcleo:
efeito solo hoje; depois a esteira da hélice e tabelas de correção (VSPAERO, CFD, túnel).

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
| `mod.zig` | entrada do módulo: `Env` (tração, torque e rotação de cada motor no instante), `induced` (soma dos efeitos a mais por painel), `hits` (máscara de painéis) |
| `README.md` | este arquivo |

## Dois jeitos de entrar

| categoria | onde | padrão | exemplo |
|---|---|---|---|
| **solo**: método de um efeito que sempre existe; um por vez | `Params.ground` | `ground_mccormick` (o que o núcleo sempre fez) | `solo.mccormick`; sem nenhum na lista = desligado |
| **aditivo**: efeito a mais, somado em cada painel | `Params.mods[0..n_mod]` | nenhum (`n_mod = 0`: o laço nem roda) | `esteira.disco` (próxima etapa), `tabela` |

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

### Limites conhecidos do `solo.mccormick`

São as razões para ter outros métodos depois:

- só reduz o arrasto induzido: não aumenta C_Lα e não muda o downwash na cauda perto do chão;
- a altura do painel usa o z dele no corpo, sem girar pela arfagem e pelo rolamento;
- usa o `b` de referência até para a EH.

### Próximos tipos (planejados; só entram com a fonte conferida)

| tipo | ideia | fontes a conferir |
|---|---|---|
| `solo.imagem` (categoria solo) | método da imagem: sistema de vórtices espelhado abaixo do chão; mexe em C_L, C_Di e no downwash da cauda, e usa a altura de cada painel com a atitude | Katz e Plotkin, *Low-Speed Aerodynamics*; Phillips e Hunsaker, *Lift and Drag of Wings in Ground Effect* (J. Aircraft, 2013) |
| `esteira.disco` (aditivo) | disco atuador por motor: velocidade axial (teoria do momento) e giro a partir do torque, sentido de rotação, contração do tubo; superposição para N motores, da frente para trás | Rankine–Froude (McCormick; Glauert em Durand, *Aerodynamic Theory*, 1935); Veldhuis (tese TU Delft, 2005); Conway (J. Fluid Mech., 1995) para carga não uniforme |
| `tabela` (aditivo) | correção por painel (Δα, fator de pressão dinâmica, ΔC_L) em função de α, β, J e comandos, gerada fora da simulação (VSPAERO, CFD, túnel); o núcleo só interpola | a fonte é a de quem gerou a tabela (fica guardada no modificador) |

## Como testar sem GUI

```
python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02                  # CSV na tela
python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02 --png solo.png   # e o gráfico
python tools/modcheck.py data/aircraft/Convencional_original.json --sem-solo
```

- O `probe` chama as funções de sonda do núcleo, sem simulação (`aerosim_probe_ground` em `root.zig`;
  `ZigBackend.probe_ground` no Python). Nenhuma conta é feita em Python.
- O `modcheck` roda a decolagem com os modificadores do avião, sem cada um e, com `--sem-solo`, sem efeito
  solo, e mostra a diferença.

Exemplo, com o `Convencional_original.json`:

| caso | decolou em (m) | saiu do chão em (m) |
|---|---|---|
| efeito solo de McCormick (padrão) | 51,381 | 39,679 |
| sem efeito solo | 51,935 (+0,554) | 40,625 (+0,946) |

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
