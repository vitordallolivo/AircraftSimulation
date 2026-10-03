# aerosim/sizing — dimensionamento inicial

Equações do diagrama de restrições (T/W exigido × carga alar W/S), sem núcleo e sem GUI. A aba
**Dimensionamento inicial** (`manager/simulations/sizing.py`) usa a polar e a tração do núcleo pela
interface `ISimSession`.

```mermaid
flowchart LR
    subgraph IF["ISimSession (núcleo)"]
        direction TB
        A1["aero_coeffs → C_D0, k, C_Lmax"]
        A2["prop_point → T(V)"]
    end
    TAB["aba Dimensionamento inicial"] --> C["constraints.py<br/>T/W(W/S) por requisito"]
    TAB --> IF
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class A1,A2 iface
    style IF fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

| requisito | T/W exigido (Gudmundsson cap. 3; Raymer cap. 5) |
|---|---|
| curva sustentada n a V | q [C_D0/(W/S) + k (n/q)² W/S] |
| razão de subida V_V a V | V_V/V + q C_D0/(W/S) + k (W/S)/q |
| cruzeiro a V | q C_D0/(W/S) + k (W/S)/q |
| corrida de decolagem S_G | V_LOF²/(2 g S_G) + q C_D,TO/(W/S) + μ (1 − q C_L,TO/(W/S)), V_LOF = 1,1 V_S |
| teto | subida residual com ρ do teto, corrigida para o nível do mar por (ρ/ρ0)^m |
| estol | W/S ≤ ½ ρ V_S² C_Lmax |

O ponto de projeto é o menor T/W viável (acima de todas as curvas, à esquerda do estol); dele saem a
área de asa (S = W/(W/S)) e a tração. Para hélice, cada requisito é comparado com a tração do motor
**na velocidade daquele requisito**, não com a estática.
