"""aerosim em Python: só o adaptador dos métodos de fora do núcleo (lltdrek, AeroSandbox e AVL, que são bibliotecas
em Python). O programa é a tela em Zig (aerosim/gui), que chama o núcleo (core/) direto; ela abre este adaptador
(`python -m aerosim.bridge`) só quando um desses métodos é marcado.
"""
