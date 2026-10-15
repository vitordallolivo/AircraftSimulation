# data — arquivos de exemplo

```sh
python -m aerosim.gui data/aircraft/Asa_voadora.json                       # GUI
cd aerodrive && zig build run -- ../data/aircraft/Asa_voadora.json        # aerodrive
```

| pasta | conteúdo |
|---|---|
| `aircraft/` | aviões prontos para abrir na GUI e no aerodrive: `Convencional_original.json`, `Asa_voadora.json`, `Bimotor_convencional_tubo_cauda_em_V.json`, `Convencional_decola_da_mesa_pousa_na_plataforma.json`; e os modelos em `.cfg`/`.xlsx` (`conventional`, `flying_wing`, `twin_boom`); os doze `S1223_*.json` do estudo (abaixo) |
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

### Aviões do estudo S1223 (`aircraft/S1223_*.json`)

Montados na interface: Aerodinâmica → Perfil e Asa, Estabilidade → Empenagem, Desempenho → Motores e Estudo. Só
estão aqui os que **voam** e que são projetos distintos. Cada um está no ponto de projeto do estudo, em Joinville
(AD 655 m). Foi mandado à Montagem pelo botão "Mandar o ponto selecionado para a Montagem", que primeiro acha a
decolagem no núcleo 6GDL e a grava no avião (acionamento e deflexão do profundor), e depois salvo com Salvar como.
A Missão e o AeroDrive decolam com esses números.

| avião | o que é |
|---|---|
| `S1223_motor_inclinado_6_Joinville.json` | EH MH 113 invertida, EV HT 14, motor inclinado 6° — o ponto ótimo do estudo |
| `S1223_monomotor_EH_convencional_Joinville.json` | EH convencional (HT 14, simétrica) com EV HT 14 |

As variantes (o mesmo avião em São José dos Campos, o motor a 0°, 3°, 9° e 12°, a EH NACA 0012) não viraram
arquivo: estão como **dados de simulação** no projeto `sprint/projeto_s1223.json` (varredura da inclinação e
comparação dos guardados, com o MTOW rápido e o 6GDL). Ficaram de fora porque não decolam na pista com a massa do
ponto de projeto: o bimotor e a cauda em V. Os resultados deles também estão nesses dados.
