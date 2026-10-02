# Simulador de missão 6GDL (monomotor convencional)

O núcleo em C integra a equação mestre do Capítulo 4 com RK4 (dt = 1 ms). O Python monta a
aeronave e o percurso, injeta tudo num arquivo de configuração, roda o C (inteiro ou por
trechos, com checkpoints), faz as análises e os gráficos. **A modularidade é o C rodando;
quem decide o que acontece em cada fase é o Python.**

## Usar

```sh
cd py
python3 rodar.py ../saida             # tudo (≈ 20 min)
python3 rodar.py ../saida --rapido    # grades menores (≈ 8 min)
```

`rodar.py` faz, nesta ordem:

1. polar estática (C_L0, C_Lα, margem, C_Lmax, V_s) e pontos de desempenho em equilíbrio;
2. decolagem: mapa s_R × δe1 e pista mínima variando x_CG e massa (só a decolagem);
3. missão em trechos, guardando checkpoints
   `A` = piloto automático liga (h_t), `B` = início da manobra 1, `C` = início da passagem LAPES;
4. LAPES a partir de `C`: o Python escolhe o ponto de soltura para a carga cair no alvo e termina a missão;
5. variantes sem sloshing e com rajada (a partir de `B`);
6. subida em regime para várias V (γ máximo; γ mínimo geométrico; planeio);
7. curvas: raio mínimo em curva nivelada (várias V; sem vento com α do piloto, sem vento com α até
   k·C_Lmax, com vento) e na manobra 1 da missão (a partir de `B`);
8. tabela por etapa (`desempenho_por_etapa.csv`) e gráficos em `png/`.

Saída em `saida/`: `aeronave.cfg`, `missao_final.cfg`, `trechos/` (checkpoints `.ckpt`, `.cfg` e
`.dat` de cada rodada), `desempenho_por_etapa.csv`, `curvas_raio_minimo.csv`, `subida.csv`,
`decolagem_mapa.dat`, `decolagem_otima.dat`, `resumo.json` e `png/`. Os CSV usam `;` e vírgula
decimal (abrem direto no Excel).

## Rodar até um ponto, mudar o resto e continuar (checkpoint)

```python
import aeronave, percurso as P, simulador as S, analises as A
av = aeronave.padrao(); pc = P.circuito()
S.escreve_cfg(av, pc, "a.cfg")
# 1) roda até o início da manobra 1 (perna 1) e guarda o estado
A.trecho("a.cfg", "tmp", "ate_B", {"para_seg": 1}, salva="tmp/B.ckpt")
# 2) muda as pernas seguintes (a curva 1 passa a ter R = 25 m; o resto do circuito se desloca)
p2 = P.altera(pc, 1, R=25.0)
S.escreve_cfg(av, p2, "b.cfg")
# 3) continua do checkpoint com a configuração nova
R = A.trecho("b.cfg", "tmp", "de_B", carrega="tmp/B.ckpt")
```

Paradas (sobrescritas na linha de comando ou no dicionário `sobre`):
`para_seg=k` (para ao entrar na perna k), `para_t=t` (para no tempo t), `para_autop=1`
(para quando o piloto automático liga). O checkpoint guarda o estado (x), os indicadores
(etapa, freio, piloto, decolou, carga solta, eventos feitos) e os eventos acumulados; os
parâmetros vêm sempre da configuração nova, então dá para trocar ganhos, vento, massa etc.
O percurso é uma corrente de pernas: mudar uma perna só desloca as seguintes, e o checkpoint
salvo antes dela continua válido.

## Análises (`py/analises.py`)

| função | o que faz |
|---|---|
| `trecho(cfg, pasta, nome, sobre, carrega, salva)` | uma rodada do C (com ou sem checkpoint) |
| `tabela_etapas(T, ev, nomes, Vs)` / `salva_csv` | distância, V mín/méd/máx, razões de subida/descida, γ, φ, n_z, α, C_L/C_Lmax, energia por etapa |
| `varre_decolagem` / `otimiza_decolagem` | pista até h_t para cada (s_R, δe1) e o mínimo por (x_CG, massa) com as restrições do artigo |
| `subida(av, pasta, Vs, r, Vlist, grads)` | nivela em cada V (checkpoint) e pede gradientes crescentes; `resumo_subida` dá γ_max(V) |
| `raio_minimo(av, perc, pasta, k, Rs, ckpt, t_ck, ...)` | roda só a curva k a partir do checkpoint para cada raio e classifica (ok / estol da asa / asa no limite de α / perda de controle / não segue / perde altura) |
| `curva_nivelada(av, perc, pasta, V, Rs, ...)` | reta longa em V (checkpoint) e 240° de curva; regime avaliado depois de 90° |
| `lapes_alvo(av, perc, pasta, ckpt, k, alvo_n)` | varredura + bisseção no ponto de soltura para a carga cair no alvo |

R mínimo = menor raio a partir do qual todos os maiores passam. Critérios: estol se
C_L/C_Lmax de alguma meia asa passa de k = 0,95 por mais de 0,3 s; segue se o erro lateral
(percentil 90 em regime) e o raio real ficam dentro de max(3 m; 0,15 R); altura se perde
menos de 3 m e não fica afundando.

## Trocar a aeronave ou o percurso

- `py/aeronave.py` → `padrao()`: massas, inércias, superfícies (meia asa interna/externa de cada
  lado, EH, EV), fuselagem, hélice (tabela J, C_T, C_P), motor, bateria, trem (TDN, TDP, cauda),
  tanque, carga LAPES, vento, decolagem, ganhos do piloto, restrições da decolagem.
- `py/percurso.py` → `circuito()` ou `monta([reta(...), curva(...), ...], eventos)`; `altera(perc, i, R=..., V=..., h=...)`.
- Qualquer escalar pode ser sobrescrito numa rodada: `{"slosh": 0}`, `{"Vw10": 0}`, `{"alfa_max": 13}`.

## Piloto automático (`piloto.c`)

- Decolagem: Riboldi et al. (2022): motor cheio, profundor δe0 até V_R (ou distância s_R) e δe1 depois.
- Longitudinal: altura → fator de carga vertical `n cosφ = cos γ_ref + K_h e_h + K_hd e_ḣ + K_ih ∫e_h`
  → α pedido (com limite α_max) → profundor (α + q com q_ref da curva). Em curva o 1/cos φ entra
  sozinho. A subida pedida diminui quando V < V_seg (prioridade da velocidade). Referência de
  altura com catraca (não devolve altura já ganha rumo ao alvo).
- Velocidade pelo acelerador, com o erro de altura somado (energia total).
- Lateral: campo vetorial na reta, órbita na curva (ganho em 1/m limitado por `Lorb`), inclinação
  de equilíbrio antecipada `tlead` s antes da curva, inclinação máxima limitada pelo fator de carga
  que a asa dá com α_max, leme zerando β.
- Pouso: rampa até o ponto de toque, arredondamento exponencial que só freia a descida.

## C

`make` gera `missao6gdl`. Uso:

```
missao6gdl missao|decolagem|polar|desempenho arquivo.cfg prefixo [--carrega x.ckpt] [--salva y.ckpt] [chave=valor ...]
```

| arquivo | conteúdo |
|---|---|
| `modelo.h` | tipos e interfaces |
| `cfg.c` | leitura da configuração (ângulos em graus no arquivo) e sobrescritas |
| `estado.c` | checkpoint: salva/carrega estado, indicadores e eventos |
| `aero.c` | painéis (asa, EH, EV) com velocidade local V + ω×r, downwash, estol, efeito solo; fuselagem |
| `propulsao.c` | hélice por tabela + motor BLDC + bateria |
| `solo.c` | TDN, TDP e cauda (molas-amortecedores com atrito, bequilha, freio) |
| `carga.c` | massa/CG/inércia variáveis, sloshing (pêndulo do 1º modo), extração LAPES |
| `trajeto.c` | segmentos e guiamento lateral |
| `piloto.c` | decolagem, piloto automático, arredondamento |
| `dinamica.c` | f(t, x), reações pelo artigo (eqs. 5–6) e RK4 |
| `desempenho.c` | equilíbrio (Newton): voo nivelado, subida máxima, planeio, curva limitada por estol e sustentada |
| `registro.c` | colunas de saída |
| `main.c` | modos, eventos, paradas e checkpoints |
