# core/src/geometry — o avião montado cabe?

Esta pasta confere se as peças de um avião montado cabem juntas, antes de qualquer conta de aerodinâmica. Aqui se
descreve o avião como um punhado de peças simples, e daqui sai se a hélice acerta alguma peça, se alguma massa
concentrada ficou fora da geometria, se o avião é uma peça só e quanto sobra entre cada peça e o chão, parado e
girado no trem principal até o ângulo de rotação da decolagem. É uma conta de microssegundos por avião, então o
otimizador (`aeroopt`) a usa como etapa barata: um avião impossível (tubo de cauda atravessando a hélice propulsora,
cauda raspando o chão na rotação) para aqui, com o motivo, sem gastar pontos de projeto.

A pasta tem um arquivo só, `geometry.zig`, com quatro partes, na ordem em que aparecem: as peças, a hélice contra as
peças, os pedaços e o chão. O tradutor que monta as peças a partir do modelo universal fica em
`aerosim/backend/zig/geometry.py`.

## As peças

Aqui se descreve um avião com até 96 peças (`Scene`). Cada peça (`Part`) é de um de três tipos, no corpo (x para a
frente, y para a direita, z para baixo). A **caixa orientada** tem um centro, três eixos unitários e a meia medida ao
longo de cada eixo: é um painel de asa, um trecho de fuselagem, um tubo ou o corpo de um motor. O **disco** é a
hélice: centro, eixo e raio. O **ponto** é uma massa concentrada (bateria, carga paga, lastro). Cada peça tem um
dono (`owner`): o motor e a hélice dele têm o mesmo, e a hélice não colide com o próprio motor.

A cena guarda também o pivô (o ponto do chão sob o trem principal), as atitudes a conferir (parado e na rotação, em
radianos, nariz para cima positivo), a folga pedida de qualquer peça e a da hélice ao chão, a distância abaixo da
qual duas caixas se encostam e se os pedaços soltos reprovam (`need_connected`).

## A hélice contra as peças

Duas caixas se cruzam pelo teorema do eixo separador: se existe uma direção em que as sombras das duas não se
sobrepõem, elas estão separadas. Para duas caixas bastam 15 direções, os 3 eixos de cada uma e os 9 produtos
vetoriais entre eles (Gottschalk, Lin e Manocha, "OBBTree", SIGGRAPH 1996; Ericson, *Real-Time Collision Detection*,
2005, seção 4.4.1; página a conferir no PDF). A sombra de uma caixa de meias medidas $h_i$ e eixos $\mathbf{a}_i$ na
direção $\mathbf{u}$ tem meia largura

$$r(\mathbf{u}) = \sum_{i=1}^{3} h_i \, |\mathbf{a}_i \cdot \mathbf{u}|$$

e as duas caixas estão separadas na direção $\mathbf{u}$ quando a distância entre os centros projetada passa da soma
das meias larguras (mais a tolerância de contato).

O disco contra uma caixa usa o corte. O plano do disco corta a caixa num polígono convexo (os pontos em que as 12
arestas da caixa atravessam o plano, em ordem de ângulo), e o disco acerta a caixa quando o centro dele cai dentro do
polígono ou quando alguma aresta do polígono passa a menos de um raio do centro. A caixa que só encosta no disco,
entrando menos de 1 mm, não conta. A peça onde a hélice está presa também não: a que tem o centro do disco a menos
de um cubo (`hub`, 3,5 cm, o raio do motor da vista 3D), como o cone do nariz que entra no cubo da tratora, a nacele
na asa ou o tubo que segura a propulsora. A espessura do disco é desprezada.
Dois discos se acertam quando a reta em que os planos deles se cortam passa por dentro dos dois círculos no mesmo
trecho; discos paralelos, só se estiverem no mesmo plano e perto.

## Os pedaços

Um avião de verdade é uma peça só: a asa do tandem precisa de um tubo até a outra, a EH precisa de um tubo ou da
fuselagem. Cada caixa é um nó de um grafo, e duas caixas que se encostam (pelo eixo separador, com a tolerância de
contato) ou que têm o mesmo dono ganham uma aresta. Os pedaços são as componentes conexas do grafo, achadas por
união e busca. O disco entra no pedaço do motor dele. Com mais de um pedaço e `need_connected`, o avião reprova; sem,
os pedaços só são contados.

## O chão

O chão é o plano que passa pelo pivô. Com o avião girado de $\theta$ (nariz para cima) em volta do eixo y do pivô, a
altura de um ponto que está a $(\Delta x, \Delta z)$ do pivô é

$$h = \Delta x \sin\theta - \Delta z \cos\theta$$

(z para baixo). Ela é linear no ponto, então o mínimo sobre uma peça sai exato, sem amostrar: na caixa, a altura do
centro menos $r(\mathbf{g})$ com $\mathbf{g} = (\sin\theta, 0, -\cos\theta)$; no disco de raio $R$ e eixo $\mathbf{n}$,
a altura do centro menos

$$R \sqrt{|\mathbf{g}|^2 - (\mathbf{g}\cdot\mathbf{n})^2}$$

A atitude parada vem do trem (a bequilha ou a roda de cauda no chão); a da rotação é a maior entre a parada e o ângulo
pedido. O trem não entra como peça: é ele que define o chão. O MDO antigo da equipe fazia a mesma conta só para a
borda de fuga da EH, com 20° menos a incidência da asa.

## Como chamar

Pela ABI, `aerosim_geometry_check(cenas, n, relatórios)` confere `n` cenas de uma vez e devolve quantas passaram. No
Python, o tradutor monta as peças a partir do modelo universal e devolve o relatório com os nomes:

```python
from aerosim.backend.zig.geometry import ZigGeometry
from aerosim.interfaces.geometry import GeometryParams
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model

r = ZigGeometry().check(build_model(conventional()), GeometryParams(rotation=12.0))
print(r.ok, r.why())          # o modelo convencional não tem tubo: a cauda aparece solta
```

Testes: `python -m ziglang build test-geometry` (dentro de `core/`) e `python -m pytest -q
tests/model/test_geometry_check.py`. Um tipo de peça novo entra como uma constante de `kind`, nas funções de
interseção e em `lowest`, e no tradutor.
