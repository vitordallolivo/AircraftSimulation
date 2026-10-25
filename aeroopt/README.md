# aeroopt — o otimizador do projeto

Este é o otimizador do AircraftSimulation, o terceiro braço ao lado do `aerosim` (onde se projeta) e do `aerodrive`
(onde se voa). Aqui se descreve um problema de otimização (quais variáveis do avião podem mudar, entre que limites,
quais restrições valem e qual nota se quer maximizar), e dele sai o melhor avião encontrado, com todas as avaliações
guardadas para ver por que ele ganhou. As contas de cada candidato rodam no núcleo em Zig; esta pasta só lê o
problema, orquestra e mostra.

Um problema de otimização é sempre a mesma frase: escolher valores para as variáveis livres, dentro dos limites, de
modo que a nota seja a maior possível sem violar as restrições. Uma **variável de projeto** é o que se escolhe e se
constrói (envergadura, perfil, motor). Uma **consequência** é o que sai das contas (MTOW, PV, EE, corrida de
decolagem): ela entra na nota ou numa restrição, nunca como variável. Um **parâmetro** é o que o regulamento ou o
local impõem (densidade do ar, limite da bateria).

A pasta se divide em três partes, na ordem em que aparecem num uso: o problema e seu arquivo (`problem.py`), os
contratos que cada peça cumpre (em `aerosim/interfaces/optim.py`) e as peças já ligadas a eles, por enquanto o
mini-MDO do núcleo (`mini_mdo.py`).

## O problema e o arquivo `.opt.json`

Aqui se define o problema inteiro num arquivo: as variáveis com tipo (contínua, inteira ou lista), limites e grupo;
as restrições (grandeza, operador, valor, ligada ou não); a nota; o avaliador; o solver e os parâmetros fixos. O
arquivo começa com `"formato": "aeroopt/1"`, e um formato desconhecido é recusado ao abrir.

`from_project` lê o problema que a página MDO de um projeto da sprint resolveria, e `apply_to_project` faz o caminho
de volta. Por isso o mesmo problema dá o mesmo resultado, bit a bit, pela GUI do aerosim ou pelo aeroopt.

### Isolar variáveis

Nem sempre se quer otimizar o avião inteiro. Às vezes a asa já está decidida e só se quer escolher a motorização, ou
o contrário. Cada variável tem um interruptor `free`: só as livres entram na busca, e as outras ficam no valor que o
avião já tem. `isolate` deixa livres só as variáveis ou os grupos citados (`asa`, `propulsão`, `requisitos`) e prende
o resto. É a mesma ideia de ligar e desligar partes no aerosim e no núcleo: o resto do avião não muda.

## Os contratos

`aerosim/interfaces/optim.py` define as quatro peças. `OptProblem` é o problema. `IScoring` dá a nota a partir das
grandezas e diz a fonte da fórmula. `IEvaluator` transforma um candidato em grandezas, no núcleo. `ISolver` propõe
os candidatos e devolve um `OptResult` com todas as avaliações e a melhor. Uma peça nova (um regulamento de outro
ano, um avaliador de maior fidelidade, outro método) entra implementando o contrato, e quem usa não muda.

## O mini-MDO do núcleo

O primeiro avaliador e o primeiro solver são o mini-MDO que já existe em `core/src/sizing`: o PSO do núcleo propõe
cada candidato e a cadeia asa → envelope → decolagem → MTOW o avalia, tudo dentro do Zig. Aqui os dois são uma
chamada só (`sizing_optimize`). O problema é aplicado numa cópia do projeto, então o projeto do usuário não muda.

## Como chamar

```python
import aeroopt
from aerosim.design.project import DesignProject
from aeroopt.mini_mdo import MiniMdoEvaluator, MiniMdoSolver

projeto = DesignProject()
pr = aeroopt.from_project(projeto, "só a envergadura")
for v in pr.variables:
    if v.key == "wing.span":
        v.lo, v.hi = 1.2, 1.8
pr.isolate("wing.span")
pr.solver.update(particles=8, iterations=5)
res = MiniMdoSolver().run(pr, MiniMdoEvaluator(projeto))
print(res.best["score"], sorted({round(r["span"], 3) for r in res.rows})[:3])
aeroopt.save(pr, "envergadura.opt.json")
```

Testes: `python -m pytest -q tests/aeroopt`. Para acrescentar uma peça, escreva uma classe que implemente o contrato
de `aerosim/interfaces/optim.py` e um teste em `tests/aeroopt`.
