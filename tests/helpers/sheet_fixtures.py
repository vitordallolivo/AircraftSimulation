"""Planilha no formato do Dados_Desempenho.xlsx (abas Geral, Superficies e Tracao) para os testes."""

GERAL = {"C8": 7.5, "C5": 15, "C9": 20, "C19": 1.2, "C21": 0.05, "C28": 2, "C29": 1.0, "G9": 0.8, "H10": 1.1,
         "I11": 1.7, "I9": -0.03, "G7": 0.01, "G6": 0.5, "G4": 0, "G5": 0, "G8": -0.06, "G12": -0.04, "G13": 0.4}
SUPERFICIES = {"M3": 0.02, "C14": 0.9, "C15": 2.4, "C16": 0.375, "C3": 0.9, "C12": 0.04, "C17": 0.06, "C4": 0.08,
               "C5": 0.35, "C6": -0.07, "C9": 2, "C13": 1.5, "C11": 1.5, "C10": 0.4, "G3": 0.18, "G4": 0.07,
               "G5": 0, "G6": 0, "G9": -1.5, "G11": 1.0, "C8": 0.35, "G8": 0.35, "J7": 0.4}
# conjuntos de tração: T(V) = p00 + p10 V + p20 V² (poly55 com o resto zero), linha = nhelice + 2
SETS = [("conjunto A", 25.0, -0.30, -0.040), ("conjunto B", 32.0, -0.45, -0.045), ("conjunto C", 20.0, -0.2, -0.03)]


def write_desempenho(path):
    from openpyxl import Workbook
    wb = Workbook()
    wb.active.title = "Geral"
    wb.create_sheet("Superficies")
    tr = wb.create_sheet("Tracao")
    for sh, d in (("Geral", GERAL), ("Superficies", SUPERFICIES)):
        for c, v in d.items():
            wb[sh][c] = v
    tr.cell(row=2, column=1, value="nome")
    for k, t in enumerate(["p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03", "p40", "p31", "p22",
                           "p13", "p04", "p50", "p41", "p32", "p23", "p14", "p05"]):
        tr.cell(row=2, column=2 + k, value=t)
    tr.cell(row=2, column=23, value="n")
    tr.cell(row=2, column=25, value="T0")
    for i, (name, p00, p10, p20) in enumerate(SETS):
        r = 3 + i
        tr.cell(row=r, column=1, value=name)
        for k in range(21):
            tr.cell(row=r, column=2 + k, value=0.0)
        tr.cell(row=r, column=2, value=p00)
        tr.cell(row=r, column=3, value=p10)
        tr.cell(row=r, column=5, value=p20)
        tr.cell(row=r, column=23, value=0.8)
        tr.cell(row=r, column=25, value=p00)
    wb.save(path)
