# data — arquivos de exemplo

```sh
python -m aerosim.gui data/aircraft/Asa_voadora.json                       # GUI
cd aerodrive && zig build run -- ../data/aircraft/Asa_voadora.json        # aerodrive
```

| pasta | conteúdo |
|---|---|
| `aircraft/` | aviões prontos para abrir na GUI e no aerodrive: `Convencional_original.json`, `Asa_voadora.json`, `Bimotor_convencional_tubo_cauda_em_V.json`, `Convencional_decola_da_mesa_pousa_na_plataforma.json`; e os modelos em `.cfg`/`.xlsx` (`conventional`, `flying_wing`, `twin_boom`); os doze `S1223_*.json` do estudo (abaixo) |
| `sprint/` | `projeto_s1223.json`: o projeto da sprint montado na interface (perfis S1223, MH 113, HT 14, SD8020; asa S1223; quatro empenagens; seis aviões) — abre em **Projeto da sprint → Abrir projeto…** |
| `airfoils/` | perfis em `.dat` (Selig): NACA, e S1223, MH 113, HT 14, SD8020 copiados sem mudança do banco de perfis do AeroSandbox; qualquer `.dat` Selig ou Lednicer funciona. Perfil invertido (EH) é uma opção da empenagem, não outro arquivo |
| `catalog/` | `catalog.cfg` e `catalog.xlsx`: motores, hélices (J, C_T, C_P), baterias, conjuntos de tração |
| `mappings/` | `dados_desempenho.json`: mapa de células do `Dados_Desempenho.xlsx` (ver `aerosim/data/README.md`) |

Os arquivos de `aircraft/` e `catalog/` são regenerados a partir de `aerosim/model/templates.py` e
`aerosim/model/catalog.py`:

```python
from aerosim.model import TEMPLATES, builtin_catalog
from aerosim.data import save_aircraft, save_catalog
for k, f in TEMPLATES.items():
    save_aircraft(f(), f"data/aircraft/{k}.cfg")
save_catalog(builtin_catalog(), "data/catalog/catalog.cfg")
```

### Aviões do estudo S1223 (`aircraft/S1223_*.json`)

Montados na interface: Aerodinâmica → Perfil e Asa, Estabilidade → Empenagem, Desempenho → Motores e Estudo. Cada
um está no **ponto de projeto** do estudo: a massa convergida pela conta rápida, com a asa e a EH recalibradas e a
altitude-densidade do lugar. Foram mandados à Montagem pelo botão "Mandar o ponto selecionado para a Montagem" e
salvos com Salvar como. Carga paga: lastro + 1 L de líquido + 1 kg de LAPES, tudo no CG.

| avião | Joinville (AD 655 m): massa / MTOW 6GDL | São José dos Campos (AD 1320 m): massa / MTOW 6GDL |
|---|---|---|
| monomotor (EH MH 113 invertida, EV HT 14) | 11,68 / 11,76 | 10,96 / 11,05 |
| motor inclinado 6° | 11,76 / 12,25 | 11,04 / 11,52 |
| bimotor | 10,92 / 10,41 | 10,27 / 9,83 |
| EH convencional (HT 14) + EV | 9,32 / 10,76 | 8,78 / 10,06 |
| EH NACA 0012 + EV NACA 0012 | 10,41 / 11,64 | 9,81 / 10,73 |
| cauda em V (MH 113 invertida) | 11,67 / 9,56 | 10,95 / 8,98 |

Onde o MTOW 6GDL fica abaixo da massa salva (bimotor e cauda em V), o avião não cabe na pista de 50 m com essa
massa: tire lastro na Montagem até o MTOW 6GDL.
