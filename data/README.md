# data — arquivos de exemplo

| pasta | conteúdo |
|---|---|
| `aircraft/` | `conventional.cfg/.xlsx` (aeronave do código original), `flying_wing.cfg`, `twin_boom.cfg` |
| `airfoils/` | perfis NACA em `.dat` (formato Selig); qualquer `.dat` Selig ou Lednicer funciona |
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
