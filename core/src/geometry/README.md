# core/src/geometry — o avião montado cabe?

Esta pasta confere se as peças de um avião montado cabem juntas, antes de qualquer conta de aerodinâmica. Aqui se
descreve o avião como um punhado de peças simples, e daqui sai se a hélice acerta alguma peça, se alguma massa
concentrada ficou fora da geometria, se o avião é uma peça só e quanto sobra entre cada peça e o chão, parado e
girado no trem principal até o ângulo de rotação da decolagem. É uma conta de microssegundos por avião, então o
otimizador (`aeroopt`) a usa como etapa barata: um avião impossível (tubo de cauda atravessando a hélice propulsora,
cauda raspando o chão na rotação) para aqui, com o motivo, sem gastar pontos de projeto.

A pasta tem um arquivo só, `geometry.zig`, com quatro partes, na ordem em que aparecem: as peças, a hélice contra as
peças, os pedaços e o chão. Quem montava as peças a partir do avião era o aerosim em Python, que saiu; por enquanto
nenhuma tela chama esta conferência.

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
2005, seção 4.4.1; página a conferir no PDF). A sombra de uma caixa de meias medidas $`h_i`$ e eixos $`\mathbf{a}_i`$ na
direção $`\mathbf{u}`$ tem meia largura

```math
r(\mathbf{u}) = \sum_{i=1}^{3} h_i \, |\mathbf{a}_i \cdot \mathbf{u}|
```

e as duas caixas estão separadas na direção $`\mathbf{u}`$ quando a distância entre os centros projetada passa da soma
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

O chão é o plano que passa pelo pivô. Com o avião girado de $`\theta`$ (nariz para cima) em volta do eixo y do pivô, a
altura de um ponto que está a $`(\Delta x, \Delta z)`$ do pivô é

```math
h = \Delta x \sin\theta - \Delta z \cos\theta
```

(z para baixo). Ela é linear no ponto, então o mínimo sobre uma peça sai exato, sem amostrar: na caixa, a altura do
centro menos $`r(\mathbf{g})`$ com $`\mathbf{g} = (\sin\theta, 0, -\cos\theta)`$; no disco de raio $`R`$ e eixo $`\mathbf{n}`$,
a altura do centro menos

```math
R \sqrt{|\mathbf{g}|^2 - (\mathbf{g}\cdot\mathbf{n})^2}
```

Quando alguma peça fica abaixo da folga pedida, o relatório diz também quanto descer as rodas, todas juntas, para
tudo livrar o chão (`gear_raise`). Descer as rodas $`\Delta`$ desce o pivô $`\Delta`$ no corpo; como as duas pernas descem
juntas, a atitude parada não muda, e a altura de todo ponto girado de $`\theta`$ sobe $`\Delta\cos\theta`$. Com a pior
folga $`f < 0`$ em cada atitude, basta

```math
\Delta = \max_\theta \frac{-f(\theta)}{\cos\theta}
```

A atitude parada vem do trem (a bequilha ou a roda de cauda no chão); a da rotação é a maior entre a parada e o ângulo
pedido. O trem não entra como peça: é ele que define o chão. O MDO antigo da equipe fazia a mesma conta só para a
borda de fuga da EH, com 20° menos a incidência da asa.

## Como chamar

`geometry.check(&cena)` confere uma cena e devolve o relatório (`checkMany` confere várias de uma vez). Um avião de cinco peças com a cauda solta, parado
e girado 12° na decolagem (`exemplo.zig`):

```zig
const std = @import("std");
const geometry = @import("aerosim").geometry;

/// uma caixa alinhada aos eixos do corpo: centro, meias medidas e o componente de onde vem
fn box(center: [3]f64, half: [3]f64, owner: i32) geometry.Part {
    return .{ .kind = .box, .owner = owner, .c = center, .h = half };
}

pub fn main() !void {
    var scene: geometry.Scene = .{ .n = 5, .pivot = .{ 0, 0, 0.2 }, .n_att = 2, .att = .{ 0, 12.0 * std.math.rad_per_deg } };
    scene.parts[0] = box(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem, nariz em x = 0,4
    scene.parts[1] = .{ .kind = .disc, .owner = 1, .c = .{ 0.42, 0, 0 }, .h = .{ 0.15, 0, 0 } }; // hélice no nariz
    scene.parts[2] = box(.{ 0, 0, -0.07 }, .{ 0.1, 0.8, 0.01 }, 2); // asa em cima da fuselagem
    scene.parts[3] = box(.{ -1.0, 0, 0 }, .{ 0.1, 0.25, 0.05 }, 3); // cauda sem tubo até a fuselagem
    scene.parts[4] = box(.{ 0.41, 0, 0 }, .{ 0.02, 0.02, 0.02 }, 1); // o motor, preso ao nariz
    const report = geometry.check(&scene);
    std.debug.print("passou: {}, hélice acertando peças: {d}, pedaços soltos: {d}\n", .{ report.ok == 1, report.n_hits, report.n_groups });
    std.debug.print("folga ao chão parado {d:.3} m, girado 12° {d:.3} m (peça {d})\n", .{ report.low[0], report.low[1], report.low_part[1] });
}
```

```
passou: false, hélice acertando peças: 0, pedaços soltos: 2
folga ao chão parado 0.050 m, girado 12° -0.082 m (peça 3)
```

A hélice presa ao motor não conta como batida, a cauda sem tubo vira um segundo pedaço e, girada 12°, ela entra 8 cm
no chão.

O exemplo roda com `python -m ziglang build exemplo -Dexemplo=geometry` e os testes com `python -m ziglang build test
-Dgrupo=geometry` (dentro de `core/`). Um tipo de peça novo entra como uma constante de `kind`, nas funções de
interseção e em `lowest`.
