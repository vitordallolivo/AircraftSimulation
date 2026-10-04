"""Projeto do zero, em etapas (a sprint): cada etapa cria uma peça e a seguinte parte dela.

    Perfil      airfoils.py   polar 2D dos candidatos (modelo, NeuralFoil ou polar do XFLR5)
    Asa         wing.py       forma em planta + linha sustentadora → asa guardada
    Empenagem   tail.py       cauda, tubo e comandos para a asa escolhida → conjunto guardado
    Motores     power.py      motores, bateria/carga no CG, trem → avião inteiro (vai para a Montagem)

Requisitos e regras em `spec.py`; o projeto (o que foi guardado em cada etapa) em `project.py`;
`results.py` transforma cada etapa em `SimResult` + gráficos para a GUI.

Nível: tudo aqui é "sprint" (contas rápidas, para comparar muitas variantes). O estudo detalhado
do avião montado continua nas simulações do manager (lltdrek/AeroSandbox, núcleo 6GDL, missão).
"""
LEVEL = "sprint"
