# data — arquivos de exemplo

```sh
python -m aerosim.gui data/aircraft/Asa_voadora.json                       # GUI
cd aerodrive && zig build run -- ../data/aircraft/Asa_voadora.json        # aerodrive
```

| pasta | conteúdo |
|---|---|
| `aircraft/` | aviões prontos para abrir na GUI e no aerodrive: `Convencional_original.json`, `Asa_voadora.json`, `Bimotor_convencional_tubo_cauda_em_V.json`, `Convencional_decola_da_mesa_pousa_na_plataforma.json`; e os modelos em `.cfg`/`.xlsx` (`conventional`, `flying_wing`, `twin_boom`) |
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
