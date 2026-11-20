# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## v0.3.2 (na `0.3_dev`, em andamento)

- "Exportar…" na Aerodinâmica e na Estabilidade gera as planilhas no formato das planilhas da equipe, com prévia.
- Na prévia, dá para escolher quais superfícies vão para a planilha.
- As análises rodam o avião como está na Montagem, mesmo sem salvar, e com a variante escolhida.
- Abrir outro avião ou projeto fecha o que estava aberto, e a linha de cima mostra o avião e o projeto em uso.
- Botão "Novo"; o nome do avião aberto brilha no topo, ao lado do projeto.
- A primeira mudança num avião montado vira uma variante, e uma janela pede o nome dela.
- O `.aero` guarda também o projeto: abrir um avião traz o projeto dele (ou nenhum), e o programa reabre o último `.aero`.
- Num avião sem projeto, as etapas avisam que não mexem nele e oferecem começar ou abrir um projeto.

## v0.3.1 (na `0.3_dev`, fechada em 2026-11-20)

- O avião passa a ser um arquivo `.aero`, com as datas dentro; os botões viram "Abrir…" e "Salvar".
- Um avião só, do projeto à Montagem e às análises.
- "Planilha…" em cada área traz dados de planilhas `.xlsx` da equipe, vistas como no Excel.
- Os dados dos gráficos e o Desempenho exportam para `.xlsx`, com prévia.
- Modo escuro opcional.
- Jeito celular da tela: barra de áreas embaixo, um gráfico por vez e entradas numa folha que sobe.
- No AeroDrive, as preferências ficam em `.aerocfg` e cada voo gravado é só `dados.csv` e `video.mp4`.

## v0.3.0 (PR da `0.2_dev` de 2026-11-19)

A série 0.2 fecha aqui: o aerosim roda inteiro sem Python, com a tela nova.

- Toda a tela, as análises, as etapas de projeto, o instalável, o site e os checks funcionam sem Python. O Python fica
  só para os métodos de fora (lltdrek, AeroSandbox, AVL), opcionais.
- Montagem completa: editar peças, acrescentar e remover, vistas lateral, superior e frontal, arrastar no 3D, variantes,
  Restaurar, Acertar o CG e Ctrl+Z.
- Aerodinâmica: uma lista de métodos para rodar (com o VLM do núcleo), polares de perfil por Reynolds, estol por
  estação e efeito solo pelo VLM.
- Missão: o modo Decolagem acha o MTOW em cada xCG da faixa de CG, mais rápido e com a missão voada no fim.
- Todos os ajustes numéricos (iterações, tolerâncias, malhas) ficam na tela, no "Refino dos Solvers".
- Biblioteca de perfis, motores e hélices compartilhada entre os projetos.
- Gráficos com títulos curtos, matemática em fonte LaTeX, leitura de valor ao clicar e altura ajustável.
- Novas contas no núcleo, ainda sem tela: V-n, esforços na asa, flambagem, divergência, flutter e trem de pouso.
- Contas longas rodam numa thread à parte, sem travar a janela; o Parar corta na hora.
- O aerosim abre no navegador, e a documentação vira um livro no site, com o tracking.

### v0.2.4 (`main`, fechada em 2026-10-30)

- Começa a tela nova em Zig (raylib), igual à antiga em PyQt.
- O aerosim, o aeroopt e o AeroDrive abrem no navegador; o AeroDrive também no celular, com manches na tela.
- Instaladores AppImage e .exe com tela inicial para os três programas.
- Análise de conjunto de asas como no túnel (uma asa, biplano, tandem, canard).
- Cargas ganham a linha sustentadora não linear, que mostra onde o estol começa.

### v0.2.3 (`main`, PR #31)

- O aeroopt ganha a janela, várias buscas (genético, evolução diferencial, CMA-ES, com substituto) e a pontuação da
  Regular 2026.
- O aeroopt confere se o avião voa: estabilidade estática e dinâmica, comandos, decolagem sem estolar e folga ao chão.
- Asas ligadas (tandem, biplano), asa voadora com elevon e caudas em H e em V.
- A decolagem ganha proteção de α no limite de estol de cada avião.
- O voo pode usar outro modelo aerodinâmico (faixas, linha sustentadora ou tabela).
- O código do núcleo fica legível, com nomes claros e erros com nome, sem mudar o resultado.

## v0.2.2 — PR #27

- Entra o mapa do código.

## v0.2.1 — PR #26

- A Missão mostra o passeio do CG e a margem estática ao longo do voo.

## v0.2.0 — fundação fechada (PRs #24–#25)

- Entram os checks de regressão.

## v0.1.x — pilha de branches mesclada (PRs #21–#23)

- Projeto do zero (sprint) por asa, em pasta, e Montagem sem exigir decolagem.
- AVL, importação do XFLR5 e polares com cache.
- Efeito solo e esteira da hélice, ligáveis por avião.
- Carga ao longo da envergadura, com vista 3D.

## v0.1.0 — ponto de partida (`main` em `033bdc1`)

- Simulação 6GDL e GUI com Aerodinâmica, Desempenho, Estabilidade e Montagem.
- AeroDrive.
- Projeto do zero (sprint).
