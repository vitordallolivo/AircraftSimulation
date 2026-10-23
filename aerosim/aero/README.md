# aerosim/aero — aerodinâmica a partir da geometria

Esta é a parte do projeto que trata da aerodinâmica do avião. Aqui se parte da geometria (as superfícies com os seus
perfis, a fuselagem, os comandos) e se tira o que o avião faz no ar: as curvas de sustentação, arrasto e momento em
função do ângulo de ataque (a polar), as derivadas de estabilidade, onde o avião estola, a melhor razão entre
sustentação e arrasto e o ponto neutro. Ela alimenta a aba **Aerodinâmica** da GUI
(`manager/simulations/aerodynamics.py`) e pode ser chamada direto do Python.

A mesma geometria passa por vários métodos de cálculo, e a aba mostra os resultados lado a lado. O principal é o
**lltdrek**, uma linha sustentadora não linear que usa a polar de cada perfil. O núcleo Zig entra para comparar,
porque é o modelo com que a simulação voa, e o AeroSandbox e o AVL são opcionais. O diagnóstico da aba diz se os
métodos concordam (e por que não), se o cruzeiro está perto do L/D máximo e qual a margem até o estol. Quando o avião
tem dispositivos de ponta de asa (winglets, placas), ele diz também se eles compensam o atrito que acrescentam.

O README começa pela geometria que entra, com a asa por partições. Depois apresenta os métodos, como eles são ligados
pela mesma interface e as equações que todos compartilham. Em seguida vêm três usos mais específicos: o estudo dos
dispositivos de ponta de asa, a tabela de voo, que deixa a simulação voar com qualquer método, e a carga ao longo das
superfícies, para a análise estrutural. No fim, como chamar e um exemplo por arquivo.

## A asa por partições

Na etapa **Aerodinâmica → Asa** da sprint (`aerosim/design/wing.py`) se define a forma da asa. Ela pode ser um
trapézio, com envergadura, afilamento e um trecho retangular, ou uma tabela de partições, como na planilha antiga. A
tabela serve para asas que mudam ao longo da envergadura: um trecho reto seguido de um afilado, outro perfil na ponta,
uma torção que cresce para fora. Cada partição soma um pedaço à envergadura, e uma asa reta é uma partição só. No
núcleo, cada trecho entre seções vira um painel de cada lado, e o avião inteiro cabe em `max_surfaces` painéis
(`core/src/limits.zig`), contando a EH e a EV, o que dá folga para várias partições.

Cada partição tem a sua envergadura (metade de cada lado), a corda no começo, o afilamento, o perfil no fim (ao longo
da partição ele passa do perfil da anterior para este), o recuo do bordo de ataque, que dá o enflechamento, e a
torção $\theta$ no fim, em relação à raiz. Uma torção negativa é o *washout*: a ponta voa com ângulo menor que a raiz e
estola depois dela. A linha sustentadora da etapa usa o perfil de cada seção no Reynolds da corda dela.

Os dois exemplos abaixo usam perfis NACA gerados, com a polar pelo NeuralFoil. O primeiro é uma asa reta, de uma
partição; o segundo junta um trecho reto a um afilado, com outro perfil na ponta.

![Asa reta: uma partição](../../docs/img/asa_reta.png)

![Asa trapezoidal: reta + afilada, outro perfil na ponta](../../docs/img/asa_trapezio.png)

Os gráficos da etapa Asa para cada uma (C_L × α, polar com arrasto induzido e de perfil, L/D e c_l ao
longo da semienvergadura no cruzeiro e no estol):

![Gráficos da asa reta](../../docs/img/asa_reta_graficos.png)

![Gráficos da asa trapezoidal](../../docs/img/asa_trapezio_graficos.png)

A trapezoidal tem mais alongamento com a mesma envergadura (menos área), e o perfil simétrico na ponta
(com washout) tira arqueamento de onde o estol seria perigoso: C_L0 e C_m,ac menores, estol mais tarde.

## Os métodos

Todo método recebe o mesmo modelo universal do avião (`aerosim/model`) e devolve a mesma `AeroPolar`, pela interface
`IAeroSolver` (`aerosim/interfaces/aero.py`). Assim a aba compara os métodos sem saber como cada um funciona por
dentro.

```mermaid
flowchart LR
    subgraph IF["aerosim/interfaces/aero.py"]
        direction TB
        I1["IAeroSolver<br/>solve(aeronave, caso) → AeroPolar"]
        I2["AeroCase / AeroPolar<br/>DERIVATIVES"]
        I3["ISectionPolar<br/>polar 2D de perfil"]
    end
    TAB["aba Aerodinâmica"] --> IF
    UM["modelo universal<br/>AircraftModel"] --> IF
    IF --> BASE["base.py<br/>polar e derivadas comuns"]
    TAB --> SV["service.py<br/>cache 3D: modelo + método + caso"]
    SV --> BASE
    BASE --> Z["zig_solver.py<br/>tradutor do backend"]
    BASE --> LLT["llt_solver.py<br/>linha sustentadora do núcleo"]
    LLT --> CORE
    BASE --> LL["lltdrek_solver.py<br/>LltdrekTranslator"]
    BASE --> ASB["asb_solver.py<br/>AsbTranslator"]
    BASE --> AVL["avl_solver.py<br/>AvlTranslator (programa avl)"]
    TAB --> XF["xflr5_import.py<br/>polar do XFLR5 (arquivo)"]
    Z --> CORE["ISimBackend.session_for"]
    LL --> SEC["sections.py — ISectionPolar<br/>modelo · NeuralFoil · arquivo<br/>cache 2D"]
    DS["design/airfoils.py<br/>etapa Perfil"] --> SEC
    TAB --> TD["tipdevices.py<br/>plano de Trefftz"]
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class I1,I2,I3 iface
    style IF fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

Os métodos diferem no que enxergam do avião e em como resolvem o escoamento:

| solver | o que entra | como |
|---|---|---|
| `zig` — núcleo Zig | asa, EH, EV, fuselagem | o mesmo modelo da simulação: faixas por seção/comando, C_Lα de Helmbold, ε = ε0 + dε/dα α, estol de Beard e McLain. Derivadas por diferenças centrais em α, β, p̂, q̂, r̂ e nos comandos (`aerosim_aero_coeffs_ex`) |
| `lltdrek` — [kuodrek/lltdrek](https://github.com/kuodrek/lltdrek) | asa + EH (com interação) | linha sustentadora não linear (Phillips–Snyder) com a polar 2D de cada perfil; sem derrapagem (derivadas em β = NaN), sem EV e sem fuselagem |
| `zig_llt`, `zig_llt_gh` — linha sustentadora do núcleo (`llt_solver.py`) | asa, EH, EV, fuselagem | a conta da simulação com as forças dos painéis pela linha sustentadora (`aerosim_aero_coeffs_llt`), com as superfícies refinadas (`span_loads.refine_all`, `n_span` faixas por lado, mais estreitas na ponta). `zig_llt`: Phillips e Snyder (2000), não converge em β nem com enflechamento; `zig_llt_gh`: Goates e Hunsaker (2021), converge e fica perto do MachUpX (`core/src/loads/README.md`). Sem estol |
| `asb_vlm` — AeroSandbox VLM | asa, EH, EV | malha de vórtices em ferradura; arrasto só induzido (+ C_D0 do modelo) |
| `asb_buildup` — AeroSandbox AeroBuildup | asa, EH, EV, fuselagem | soma por componentes com NeuralFoil; arrasto completo |
| `asb_ll` — AeroSandbox LiftingLine | asa, EH, EV | linha sustentadora com NeuralFoil; só derivadas em α e β |
| `avl` — [AVL](https://web.mit.edu/drela/Public/web/avl/) (Drela e Youngren) | asa, EH, EV, dispositivos, comandos | malha de vórtices; o programa `avl` é externo (PATH ou `AVL_PATH`). O tradutor escreve o `.avl` (NACA pelo código, os outros perfis por AFILE, C_D0 do modelo como CDp, comandos `pitch`/`roll`/`yaw` pelos ganhos da mistura), roda a varredura numa sessão e lê o `ST` de cada ponto |
| `xflr5` — polar importada | o que estava no XFLR5 | lê a polar de avião exportada (Polars → Export, texto ou CSV): α, C_L, C_D, C_Di, C_m (no CG de lá); C_Lα e C_mα pelo ajuste em α; não roda nada |

Cada método só implementa `evaluate(modelo, caso, pontos)`, que leva pontos de voo universais (α, β, as taxas
$\hat p, \hat q, \hat r$ e os comandos) a coeficientes universais. O tradutor de cada um faz a ida, do modelo
universal para o formato dele, e a volta, do resultado para os eixos e a adimensionalização universais. A varredura
em α e as diferenças centrais das derivadas são o mesmo código para todos (`base.py`). Todos devolvem nos eixos do
simulador (x à frente, z para baixo), com os momentos no ponto `ref` do caso, que é o x_CG escolhido na aba (em % da
CMA, a corda média aerodinâmica) ou o CG do modelo de massa. Os métodos externos usam x para trás e z para cima
(`geometry.to_xz_up`); o lltdrek usa velocidade livre unitária (ω entra dividido por V) e normaliza C_l e C_n por
$S\,c$; o adaptador converte. Sem `lltdrek`, `aerosandbox` ou o programa `avl` instalados, o método aparece como
indisponível na aba, com o motivo.

**Polar 2D dos perfis (`sections.py`).** Os métodos que usam a polar de cada perfil (o lltdrek e a etapa Perfil da
sprint) pedem a mesma função, `section_polar(perfil, α, Re, fonte)`. Cada fonte é um `ISectionPolar`:

| fonte | o que é |
|---|---|
| `modelo` | c_l = a0 (α − α_L0) misturado à placa plana pela sigmoide de Beard e McLain, pico no c_l,max do perfil (a hipótese do núcleo, em 2D) |
| `neuralfoil` | o contorno real (.dat ou NACA) pela rede do NeuralFoil; sem contorno, cai no modelo |
| `arquivo` | a polar exportada pelo XFLR5/XFOIL |

No lltdrek, cada estação do modelo universal carrega o perfil dela. O tradutor escreve uma polar por perfil
diferente, e o lltdrek mistura linearmente entre as estações, como a etapa Asa.

**Cache.** A mesma pergunta não roda de novo:

| | chave | onde |
|---|---|---|
| 2D (`sections.py`) | perfil (nome, contorno, números, invertido) + fonte + arquivo e data + Re (em mil) + α | memória; NeuralFoil também em disco |
| 3D (`service.py`) | configuração inteira + método + versão dele + caso (V, α, ref, ρ, polar 2D, painéis) | memória; métodos caros (lltdrek, AeroSandbox, AVL) também em disco |

O disco é `~/.cache/aerosim` (ou a pasta da variável `AEROSIM_CACHE`), nunca o repositório nem `data/`. Na aba, o
resumo mostra de onde veio cada resultado: `calculado`, `cache` ou `arquivo …`. Cada `AeroPolar` sai também com a
`fidelity` do método (`modelo` < `llt` < `vlm` < `painel` < `cfd` < `ensaio`), para depois calibrar o método barato
pelo caro.

O adaptador do lltdrek 1.2 contorna duas coisas da biblioteca: o corretor de Newton só monta a matriz certa quando
todas as superfícies têm o mesmo número de painéis, então o adaptador sempre usa o mesmo N; e o `np.cross` em vetores
soltos dominava o tempo, então o adaptador o troca por uma versão de 3 componentes.

![Polares por método](../../docs/img/comparativo/conventional_aero_graficos.png)
![Derivadas por método](../../docs/img/comparativo/conventional_aero_diagnostico.png)
![Métricas por método](../../docs/img/comparativo/flying_wing_aero_diagnostico.png)

## Equações comuns aos métodos

**Taxas adimensionais.** Todos os métodos recebem e devolvem as rotações assim:

$$
\hat p = \frac{p\,b}{2V} \qquad \hat q = \frac{q\,c}{2V} \qquad \hat r = \frac{r\,b}{2V}
$$

**Derivadas** (`base.py`). Diferença central em torno do ponto da derivada ($\alpha_d$, com o resto zero), com o mesmo
passo $h$ para todos os métodos; $x$ é $\alpha$, $\beta$, $\hat p$, $\hat q$, $\hat r$ ou um comando, e $C$ um dos
coeficientes:

$$
C_x = \frac{C(x + h) - C(x - h)}{2h}
$$

**Métricas da polar** (`polar_metrics`). O $C_{L\alpha}$ e o $C_{m\alpha}$ são as inclinações no trecho linear; o ponto
neutro e a margem estática, com $c$ a corda de referência (x à frente):

$$
x_{np} = x_{ref} + c\,\frac{C_{m\alpha}}{C_{L\alpha}}
\qquad
MS = \frac{x_{ref} - x_{np}}{c}
$$

O fator de Oswald sai do ajuste da parte induzida, e a polar parabólica (`parabolic_polar`) do ajuste por mínimos
quadrados no trecho linear:

$$
C_{D_i} = \frac{C_L^2}{\pi\,AR\,e}
\qquad
C_D = C_{D0} + k\,C_L^2
$$

**Polar 2D "modelo"** (`sections.py`). A mesma hipótese do núcleo em 2D: a reta $c_l = a_0\,(\alpha - \alpha_{L0})$
misturada à placa plana pela sigmoide $\sigma$ de Beard e McLain, com o ângulo de estol achado para o pico ser o
$c_{l,max}$ do perfil (a sigmoide está em [`core/src/physics/README.md`](../../core/src/physics/README.md)):

$$
c_l = (1 - \sigma)\,a_0\,(\alpha - \alpha_{L0}) + \sigma\;2\operatorname{sgn}(\alpha)\sin^2\alpha\cos\alpha
\qquad
c_d = c_{d0} + 1{,}2\,\sigma\sin^2\alpha
$$

**Reynolds** (`geometry.py`), com a viscosidade cinemática do ar na densidade dada:

$$
Re = \frac{V\,c}{\nu(\rho)}
$$

## Dispositivos de ponta de asa (`tipdevices.py`)

Um dispositivo de ponta (winglet, placa de ponta, caixa, asa em C) diminui o arrasto induzido, mas acrescenta área
molhada e, com ela, atrito. Este estudo diz quanto cada forma ganha e quando o ganho paga o atrito.

Arrasto induzido mínimo no plano de Trefftz (Munk, 1921; Kroo, *Drag due to lift*, Annu. Rev. Fluid Mech. 33, 2001;
Kroo, McMasters e Smith, *Highly nonplanar lifting systems*, 1995). O arrasto induzido de qualquer sistema sustentador
depende só do traço da esteira no plano de Trefftz e da circulação $\Gamma(s)$ ao longo dele:

$$
L = \rho\,V\oint\Gamma\,dy
\qquad
D_i = -\frac{\rho}{2}\oint\Gamma\,w_n\,ds
$$

$w_n$ é a velocidade normal ao traço que os vórtices livres ($d\Gamma/ds$) induzem nele. Com o traço dividido em
painéis de $\Gamma$ constante (espaçamento uniforme: o cosseno não converge nas junções), as duas integrais viram
formas em $\Gamma$, e o mínimo de $D_i$ com $L$ fixo é um sistema linear (a condição de Munk, $w_n \propto \cos\theta$):

$$
D_i = \Gamma^T M\,\Gamma \qquad L = b^T\Gamma \qquad M\,\Gamma \propto b
$$

O fator de eficiência do vão compara com a asa plana elíptica ($e = 1$), e a extrapolação de Richardson em $n$ e $2n$
painéis tira o erro da malha:

$$
e = \frac{L^2}{\pi\,q\,b^2\,D_i}
$$

A placa de ponta também é comparada com a correção empírica do Raymer (*Aircraft Design*, eq. 12.48):

$$
AR_{ef} = AR\,\left(1 + 1{,}9\,\frac{h}{b}\right)
$$

Os testes (`tests/aero/test_tipdevices.py`) conferem a asa plana ($e = 1$), a caixa contra Kroo 2001 e a placa contra o
Raymer; os números esperados estão lá.

`device_study` varre $h/b$ e dá, para winglet, placa, caixa e asa em C, o $e$ ótimo e a variação do arrasto total em
relação à asa sem nada; $e_{plan}$ é a perda da asa real em relação ao carregamento ótimo:

$$
\frac{D}{q} = \frac{(C_L S)^2}{\pi\,b^2\,e\,e_{plan}} + C_f\,S_{molhada}
$$

Ele dá também duas referências de
extensão de ponta: com a mesma área molhada e com o mesmo momento fletor na raiz (comparação de
Whitcomb/Jones). Com carregamento ótimo a extensão ganha; o winglet compensa quando o vão é limitado
(regulamento, hangar).

![Pontas de asa](../../docs/img/comparativo/flying_wing_aero_graficos.png)

## Tabela de voo de qualquer método (`flight_table.py`)

A simulação voa com o modelo do núcleo, mas às vezes se quer voar com a aerodinâmica de outro método (lltdrek,
AeroSandbox, AVL), que não roda dentro do núcleo. Para isso o método gera uma tabela antes do voo, e o núcleo voa com
ela (`ac.sim.aero_model = "tabela"`, `core/src/physics/aerotable.zig`). A tabela tem C_L, C_D e C_m numa faixa de α,
a uma velocidade, sem derrapagem, e as derivadas lineares em β, nas taxas e nos comandos, tomadas num α pequeno. As
equações com que o núcleo voa essa tabela estão em [`core/src/physics/README.md`](../../core/src/physics/README.md).

As derivadas que o método não dá (NaN) vêm do método `fill`, em geral o núcleo, e a tabela guarda quais vieram dele.
As polares passam pelo cache, então a mesma tabela não é montada de novo. Os métodos de fora não têm a fuselagem
(`IAeroSolver.includes_fuselage = False`), e o núcleo soma a dele por cima. A tabela não tem efeito solo, esteira da
hélice, variação com a velocidade nem estol nos métodos lineares. Para comparar os voos com cada modelo:
`tools/aero/missao.py`.

```python
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional
backend, ac = ZigBackend(), conventional()
from aerosim.aero import solver_by_name
from aerosim.aero.flight_table import table
from aerosim.model.universal import build_model
model = build_model(ac)
cg = tuple(model.mass["cg"])                        # momentos no CG
t = table(solver_by_name(backend, "avl"), model, V=15.0, rho=1.225, ref=cg, fill=solver_by_name(backend, "zig"))
ac.sim.aero_model, ac.sim.aero_table = "tabela", t        # t["completadas"]: as derivadas que vieram do núcleo
```

## Carga ao longo das superfícies (`span_loads.py`)

Esta é a análise de cargas da aerodinâmica: como a sustentação e o arrasto se distribuem ao longo de cada superfície
num ponto de operação. Por padrão o ponto é o voo nivelado, com α, profundor e acelerador saindo da trimagem do
núcleo, então a distribuição é a da carga real do avião, com as superfícies sustentando o peso. Dá para mudar a
velocidade (`V`), pedir uma curva com fator de carga `n` maior que 1 (se o avião não segura aquele n naquela
velocidade, a trimagem avisa em `notes`) ou impor α, profundor (`de`) e a rotação de cada motor (`rpm`).

Para cada superfície (asa, EH, EV, cauda em V, dispositivos), o resultado traz, ao longo da envergadura em metros, a
sustentação e o arrasto por metro, o α local, a velocidade e a pressão dinâmica locais, o $c_l$ e o $c_d$, e os
vetores de cada faixa (centro, força, velocidade relativa e a parte induzida pelos modificadores), que a vista 3D
desenha. `tubes()` dá o contorno da esteira de cada motor, também para o 3D.

O método da carga é escolhido em `LoadCase(method=...)`. O padrão, `"llt"`, é a linha sustentadora do núcleo de
Phillips e Snyder (`core/src/loads/`): a carga depende do alongamento e da forma, cai na ponta, e o downwash da asa
na cauda sai das pernas dos vórtices. `"llt_gh"` é a mesma linha sustentadora com as correções de Goates e Hunsaker,
que dão um resultado confiável também em asa enflechada e em derrapagem (o vento chegando de lado). `"faixas"` é o
modelo da simulação, em que cada superfície tem a mesma inclinação de sustentação em toda a envergadura e a carga sai
plana; serve para comparar. `"vlm_asb"` é o VLM do AeroSandbox, para a tendência. A explicação de cada método e das
correções está em [`core/src/loads/README.md`](../../core/src/loads/README.md).

A conta é do núcleo, no mesmo laço da simulação (`aero.computeTrace` via `aerosim_panel_states`), e entra com os
modificadores do avião (efeito solo, esteira). O estado do motor vem de `aerosim_prop_state`, com a hélice em
$C_T(J)$ e $C_P(J)$ na rotação pedida. O módulo só refina a geometria para dar resolução: põe mais seções na mesma
superfície (corda, recuo e torção interpolados, com as seções originais exatas), mais estreitas na ponta, até o
limite de painéis do núcleo. Sem motor, a sustentação total refinada é a mesma da sem refino, e um teste confere isso.
Com `LoadCase(props=False)`, a tração e o torque são zerados e a distribuição sai a do avião limpo.

**Entrada padrão, gráficos e 3D.** `to_result(r, backend)` leva o resultado para a entrada padrão
`aerosim.interfaces.loads.LoadResult`: as distribuições ao longo da envergadura, a malha 3D (uma face por faixa), os
campos (carga alar local, sustentação por metro, α efetivo, V local / V∞, c_l, c_d, q, imersão na esteira), os
vetores e os tubos da esteira. Quem desenha só lê esse formato: `load_plots.span_figure` faz os gráficos e
`gui/widgets/load_view.LoadView` faz o 3D. Por isso outro método (VLM, painéis, CFD) entra montando um `LoadResult`,
sem mexer nos gráficos nem no 3D; `tests/aero/test_load_result.py` faz isso com um "CFD" de mentira.

A vista 3D pinta o próprio modelo da GUI, e cada vértice pega o valor da faixa mais próxima. As setas mostram a força
total da faixa, a sustentação (perpendicular ao vento local), a força normal à superfície ou a velocidade induzida, e
as de força são por metro de envergadura, como as distribuições; em N por faixa, as faixas mais estreitas das quebras
de seção pareceriam uma queda de carga que não existe. A força total e a sustentação ficam em camadas separadas
porque, com α grande, a sustentação se inclina para a frente em relação à normal da asa. O mapa de cores pode ir do
mínimo ao máximo, ser simétrico em zero ou ter uma faixa por superfície, para ver a variação na EH mesmo com a asa
carregando muito mais.

A trimagem ainda não vê a esteira (ela chama a aerodinâmica sem motores). Com a esteira ligada, α e profundor são os
do avião sem esteira, e a sobra de sustentação aparece no resultado. Os testes estão em
`tests/aero/test_span_loads.py`.

**O que o tubo da hélice pega (`collision.py`).** `tube_hits(backend, ac, V=0, thrust=None)` traça, a partir de cada
hélice, um tubo ao longo do eixo de tração: um cilindro do raio da hélice sem tração, ou o tubo que contrai com ela.
Cada coisa que o tubo pega vem como `Hit(prop, component, kind, fraction)`, com a fração da área para as superfícies e
a fração dos vértices do modelo da GUI para os objetos (fuselagem, trem, carga). A geometria é a do núcleo
(`core/src/collision/`), a mesma que a esteira usa.

## Como chamar

O caso mais comum é a polar de um método:

```python
import numpy as np
from aerosim.aero import AeroCase, ZigPanelSolver, LltdrekSolver, AsbVLMSolver, polar_metrics
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model

ac = conventional()
model = build_model(ac)
case = AeroCase(V=15, alphas=np.arange(-4, 14, 1.0), ref=(0.02, 0, 0.0))   # ref: ponto dos momentos
pol = ZigPanelSolver(ZigBackend()).solve(model, case)      # ou LltdrekSolver(), AsbVLMSolver() se instalados
pol.CL, pol.CD, pol.derivs                                  # polar e derivadas (C_mα, C_nβ, C_lp, ...)
polar_metrics(pol, model, case)                             # C_Lmax, α de estol, (L/D)máx, ponto neutro...
```

`lltdrek` e `aerosandbox` são opcionais (`pip install -r requirements-aero.txt`).

A tabela de voo, a carga ao longo das superfícies e a colisão com o tubo:

```python
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional
backend, ac = ZigBackend(), conventional()
from aerosim.aero.span_loads import LoadCase, compute
r = compute(backend, ac)                                      # nivelado a 12 m/s (trimagem)
r = compute(backend, ac, LoadCase(V=16, n=2))                 # curva com n = 2 a 16 m/s
r = compute(backend, ac, LoadCase(V=8, alpha=2, rpm=6000))     # α e rotação impostos (rpm: um valor ou um por motor)
r.alpha, r.de, r.weight, r.trim                               # o que foi usado
asa = r.by_role("wing")[0]
asa.s, asa.L, asa.alpha, asa.V                                # y (m), N/m, °, m/s
asa.points, asa.force, asa.velocity, asa.induced              # (n, 3), corpo
r.props[0].T, r.props[0].Q, r.props[0].J                      # motor naquela rotação
```

```python
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional
backend, ac = ZigBackend(), conventional()
from aerosim.aero.collision import tube_hits
for h in tube_hits(backend, ac):
    print(h.prop, h.component, h.kind, h.fraction)
```

Pela linha de comando:

```
python tools/span_load.py data/aircraft/Convencional_original.json --com esteira.disco --png carga.png   # 12 m/s
python tools/span_load.py data/aircraft/Convencional_original.json --V 15 --n 2 --png curva.png
python tools/span_load.py data/aircraft/Convencional_original.json --V 8 --alpha 2 --rpm 6000 --com esteira.disco
```

```
python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco                 # janela 3D
python tools/load_view.py data/aircraft/Convencional_original.json --campo alpha_ef --png vista.png
python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco --sem-helice --png limpo.png
```

Figuras do comparativo: `python tools/plot_comparativo.py docs/img/comparativo [conventional|twin_boom|flying_wing|arquivo.cfg]`.

## Um exemplo por arquivo

Todos partem do avião de exemplo e do backend do núcleo:

```python
import numpy as np
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model

be, ac = ZigBackend(), conventional()
model = build_model(ac)

# __init__.py: a lista de métodos, um pelo nome, as métricas e a polar parabólica
from aerosim.aero import AeroCase, all_solvers, solver_by_name, polar_metrics, parabolic_polar
case = AeroCase(V=15.0, alphas=np.arange(-4, 13, 2.0))
print([s.name for s in all_solvers(be)])

# zig_solver.py (o núcleo) e base.py (a varredura e as derivadas, iguais para todos)
pol = solver_by_name(be, "zig").solve(model, case)
print(polar_metrics(pol, model, case)["x_np"], parabolic_polar(pol)["CD0"], pol.derivs["Cma"])

# llt_solver.py: a linha sustentadora do núcleo como método de polar (Goates e Hunsaker)
from aerosim.aero.llt_solver import CoreLLTSolver
print(CoreLLTSolver(be, gh=True).solve(model, case).CL[:3])

# service.py: a mesma pergunta com cache (a segunda vez não roda de novo)
from aerosim.aero import service
pol2 = service.solve(solver_by_name(be, "zig"), model, case)

# sections.py: a polar 2D de um perfil, pela fonte escolhida
from aerosim.aero.sections import section_polar
af = ac.surfaces[0].airfoil
print(section_polar(af, [0, 4, 8], Re=2e5, source="modelo")["cl"])

# geometry.py: Reynolds e eixos dos solvers externos
from aerosim.aero.geometry import reynolds, to_xz_up
print(reynolds(15.0, 0.3, 1.225), to_xz_up([1.0, 0.5, 0.2]))

# tipdevices.py: eficiência do vão no plano de Trefftz e o estudo de dispositivos
from aerosim.aero.tipdevices import span_efficiency, device_study
print(span_efficiency("caixa", h=0.2), device_study(2.0, 0.6, 0.6, 0.2)["h_b"][:3])

# span_loads.py: carga ao longo das superfícies (trimado a 12 m/s) e a entrada padrão dos gráficos
from aerosim.aero.span_loads import LoadCase, compute, to_result
r = compute(be, ac, LoadCase(V=14.0))
res = to_result(r, be)

# load_plots.py: os gráficos ao longo da envergadura a partir do LoadResult
from aerosim.aero.load_plots import span_figure
fig = span_figure([("núcleo", res)])

# load_geometry.py: as setas da vista 3D (linhas e cones)
from aerosim.aero.load_geometry import arrow_meshes
m = arrow_meshes(np.zeros((1, 3)), np.array([[0.0, 0.0, 1.0]]), head=0.1)

# collision.py: o que o tubo de cada hélice pega
from aerosim.aero.collision import tube_hits
print(tube_hits(be, ac)[:2])

# flight_table.py: a tabela de voo de um método, para o núcleo voar com ela
from aerosim.aero.flight_table import table
t = table(solver_by_name(be, "zig"), model, V=15.0, rho=1.225)
```

Os métodos de fora seguem a mesma interface (`solve(model, case)`), cada um com o seu tradutor:

```python
import numpy as np
from aerosim.aero import AeroCase
from aerosim.aero.asb_solver import AsbVLMSolver            # asb_solver.py: VLM, AeroBuildup e LiftingLine do AeroSandbox
from aerosim.aero.avl_solver import AvlSolver, has_optvl    # avl_solver.py: o AVL (programa ou optvl)
from aerosim.aero.lltdrek_solver import LltdrekSolver       # lltdrek_solver.py: linha sustentadora não linear
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model

model = build_model(conventional())
case = AeroCase(V=15.0, alphas=np.arange(0, 9, 4.0))
for s in (AsbVLMSolver(), AvlSolver(), LltdrekSolver()):
    if s.available() is None:                               # None: instalado
        print(s.name, s.solve(model, case).CL)
```

E a polar exportada do XFLR5 (`xflr5_import.py`) entra como mais um método, lida de um arquivo:

```python
# não roda sozinho: precisa de um arquivo exportado do XFLR5
from aerosim.aero.xflr5_import import read_plane_polar, Xflr5PolarFile
d = read_plane_polar("minha_polar.txt")          # alpha, CL, CD, CDi, Cm
metodo = Xflr5PolarFile("minha_polar.txt")
```
