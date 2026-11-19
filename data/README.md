# data — arquivos de exemplo

```sh
python -m ziglang build aerosim                                            # GUI (abre os aviões de data/aircraft)
cd aerodrive && zig build run -- ../data/aircraft/Asa_voadora.aero        # aerodrive
```

| pasta | conteúdo |
|---|---|
| `aircraft/` | aviões prontos para abrir na GUI e no aerodrive: `Convencional_original.aero`, `Asa_voadora.aero`, `Bimotor_convencional_tubo_cauda_em_V.aero`, `Convencional_decola_da_mesa_pousa_na_plataforma.aero`; e os modelos em `.cfg`/`.xlsx` (`conventional`, `flying_wing`, `twin_boom`) |
| `sprint/` | `projeto_s1223.json`: o projeto da sprint montado na interface (perfis S1223, MH 113, HT 14, SD8020; asa S1223; quatro empenagens; seis aviões) — formato antigo (um .json só): abre em **Projeto da sprint → Abrir projeto antigo…** e passa a gravar em `<meus aviões>/sprint/projeto_s1223/`, um arquivo por asa (nada é gravado em `data/`) |
| `airfoils/` | perfis em `.dat` (Selig): NACA, e S1223, MH 113, HT 14, SD8020 copiados sem mudança do banco de perfis do AeroSandbox; qualquer `.dat` Selig ou Lednicer funciona. Perfil invertido (EH) é uma opção da empenagem, não outro arquivo |
| `catalog/` | `catalog.cfg` e `catalog.xlsx`: motores, hélices (J, C_T, C_P), baterias, conjuntos de tração |
| `catalog/tracao_equipe.json` | polinômios de tração da equipe (poly55, x = n, y = V, P em kgf, T = g·(ρ/ρ0)·P), as linhas como vieram e os pendentes (o 16x4E 630kV não reproduz o T0: ajuste normalizado sem μ e σ). Todo `.json` de `catalog/` entra no catálogo da interface |
| `airfoils/` | a pasta padrão de perfis (`.dat`): o Mini-MDO e o seletor de perfis listam todos (polar do NeuralFoil) |
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

O `.aero` é o arquivo do avião: um zip com o `manifesto.zon` (formato, versão, programa, quando foi criado e
modificado, nome) e o `aviao.zon` (o avião em ZON, a notação de objetos do Zig, que se lê como texto). O programa
ainda abre o `.json` antigo, e o Salvar grava sempre `.aero`.
