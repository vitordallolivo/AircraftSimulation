"""O caminho da busca em coordenadas paralelas: cada avião é uma linha que passa por um eixo por variável livre e por
um eixo por resultado (MTOW, PV, nota).

O mapa dos aviões mostra duas grandezas por vez. Com cinco variáveis livres, ver qual combinação deu as melhores notas
pede dez mapas. Nas coordenadas paralelas (Inselberg, "The plane with parallel coordinates", The Visual Computer 1(2),
1985, a conferir no PDF) todas aparecem juntas: os eixos ficam lado a lado, cada um na escala da sua faixa, e um avião
é a linha que liga os valores dele. As linhas das boas notas que se juntam num trecho do eixo dizem que ali está a
região boa; as que se cruzam entre dois eixos dizem que as duas variáveis se trocam (mais de uma pede menos da outra).

A cor é a geração em que o avião entrou, e a linha grossa é o caminho da busca: o melhor até ali, avião por avião, na
ordem em que foram avaliados. É ela que mostra por onde a busca andou até chegar ao melhor. Uma lista (a hélice, a
categoria) vira um eixo com uma marca por opção.

A janela desenha isso embaixo do mapa, e `write_html` grava a mesma figura numa página só, sem internet, com um
controle para ver a busca até uma geração e o avião que está embaixo do mouse.

    d = data(problem, rows)                   # os eixos, as linhas (de 0 a 1 em cada eixo) e o caminho
    write_html(problem, rows, "rodadas_aeroopt/micro/caminho.html")
"""
from __future__ import annotations

import html as _html
import json
import math

from aerosim.interfaces.optim import OptProblem

from . import categories as cat
from . import inputs as inp

RESULTS = (("mtow", "MTOW na pista (kg)"), ("pv", "PV (kg)"), ("nota", "nota"))


def _label(key: str) -> str:
    if key == cat.KEY:
        return "categoria"
    i = inp.get(key)
    return f"{i.label} ({i.unit})" if i is not None and i.unit else (i.label if i is not None else key)


def _key(r: dict) -> tuple:
    """a ordem do melhor: voo válido antes de inválido, depois a nota"""
    n = r.get("nota", math.nan)
    return (bool(r.get("valido")), n if math.isfinite(n) else -math.inf)


def path(rows: list[dict]) -> list[str]:
    """o caminho da busca: na ordem de avaliação, cada avião que passou a ser o melhor até ali"""
    out, best = [], None
    for r in sorted(rows, key=lambda r: r.get("index", 0)):
        if math.isfinite(r.get("nota", math.nan)) and (best is None or _key(r) > _key(best)):
            best = r
            out.append(r["name"])
    return out


def data(problem: OptProblem, rows: list[dict]) -> dict:
    """os eixos (chave, nome, faixa ou opções) e as linhas (o valor de cada avião em cada eixo, de 0 a 1, NaN onde
    não há), mais o caminho da busca"""
    keys = [v.key for v in problem.free_variables()]
    if any(cat.KEY in r.get("values", {}) for r in rows) and cat.KEY not in keys:
        keys.insert(0, cat.KEY)
    raw = {k: [r.get("values", {}).get(k) for r in rows] for k in keys}
    raw.update({k: [r.get(k, math.nan) for r in rows] for k, _ in RESULTS})
    axes = []
    for k in keys + [k for k, _ in RESULTS]:
        vals = raw[k]
        num = [float(v) for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)
               and math.isfinite(float(v))]
        if all(v is None or (isinstance(v, (int, float)) and not isinstance(v, bool)) for v in vals):
            var = next((v for v in problem.variables if v.key == k), None)
            lo, hi = (min(num), max(num)) if num else (0.0, 1.0)
            if var is not None and var.kind == "contínua":
                lo, hi = min(lo, var.lo, var.hi), max(hi, var.lo, var.hi)   # a faixa do problema inteira
            axes.append(dict(key=k, label=_label(k) if k not in dict(RESULTS) else dict(RESULTS)[k], kind="num",
                             lo=lo, hi=hi, names=[]))
        else:
            names = sorted({str(v) for v in vals if v is not None})
            axes.append(dict(key=k, label=_label(k), kind="lista", lo=0.0, hi=max(len(names) - 1, 1), names=names))
    lines = []
    for j, r in enumerate(rows):
        ys = []
        for a in axes:
            v = raw[a["key"]][j]
            if a["kind"] == "lista":
                y = a["names"].index(str(v)) / max(len(a["names"]) - 1, 1) if v is not None else math.nan
            elif v is None or not math.isfinite(float(v)):
                y = math.nan
            else:
                y = (float(v) - a["lo"]) / (a["hi"] - a["lo"]) if a["hi"] > a["lo"] else 0.5
            ys.append(y)
        lines.append(dict(name=r["name"], index=r.get("index", 0), gen=r.get("geração", 0) or 0, ys=ys,
                          nota=r.get("nota", math.nan), valido=bool(r.get("valido")), alive=bool(r.get("alive")),
                          values=[raw[a["key"]][j] for a in axes]))
    lines.sort(key=lambda d: d["index"])
    return dict(axes=axes, lines=lines, path=path(rows), generations=max((d["gen"] for d in lines), default=0))


def _json(d) -> str:
    def clean(x):
        if isinstance(x, float) and not math.isfinite(x):
            return None
        if isinstance(x, dict):
            return {k: clean(v) for k, v in x.items()}
        if isinstance(x, (list, tuple)):
            return [clean(v) for v in x]
        return x
    return json.dumps(clean(d), ensure_ascii=False).replace("</", "<\\/")


PAGE = """<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root { --bg:#fff; --fg:#1b2430; --muted:#5a6676; --axis:#8a94a3; --path:#000; }
@media (prefers-color-scheme: dark) { :root { --bg:#12161c; --fg:#e6eaf0; --muted:#9aa6b5; --axis:#5c6675; --path:#fff; } }
body { margin:0; padding:16px; background:var(--bg); color:var(--fg); font:14px/1.45 system-ui, sans-serif; }
h1 { font-size:1.25rem; margin:0 0 4px; } p { margin:0 0 10px; color:var(--muted); max-width:80ch; }
.bar { display:flex; gap:16px; align-items:center; flex-wrap:wrap; margin:8px 0; }
svg { width:100%; height:auto; display:block; } svg text { paint-order:stroke; stroke:var(--bg); stroke-width:3px; } .tip { min-height:3em; color:var(--muted); white-space:pre-wrap; }
</style></head><body>
<h1>__TITLE__</h1>
<p>Cada linha é um avião, e cada eixo vertical é uma variável livre ou um resultado, na escala da sua faixa. A cor é
a geração em que o avião entrou, de clara (a primeira) a escura. A linha grossa é o caminho da busca: o melhor até
ali, na ordem em que os aviões foram avaliados. A linha tracejada é de um avião que parou numa etapa.</p>
<div class="bar"><label>até a geração <input id="gen" type="range" min="0" value="0"> <b id="genv"></b></label>
<label><input id="only" type="checkbox"> só o caminho</label></div>
<svg id="pc" viewBox="0 0 1200 520" role="img" aria-label="coordenadas paralelas"></svg>
<div class="tip" id="tip">passe o mouse numa linha</div>
<script>
const D = __DATA__;
const W = 1200, H = 520, L = 70, R = 70, T = 40, B = 50;
const svg = document.getElementById("pc"), tip = document.getElementById("tip");
const gen = document.getElementById("gen"), genv = document.getElementById("genv"), only = document.getElementById("only");
gen.max = D.generations; gen.value = D.generations;
const n = D.axes.length, X = k => L + (n > 1 ? k * (W - L - R) / (n - 1) : (W - L - R) / 2);
const Y = y => T + (1 - y) * (H - T - B);
const NS = "http://www.w3.org/2000/svg";
const el = (t, a) => { const e = document.createElementNS(NS, t); for (const k in a) e.setAttribute(k, a[k]); return e; };
const fmt = v => v === null || v === undefined ? "—" : (typeof v === "number" ? (+v.toPrecision(4)).toLocaleString("pt-BR") : String(v));
function color(g) {                       // de claro a escuro pela geração (viridis aproximado)
  const t = D.generations ? g / D.generations : 1;
  const c = [[253,231,37],[94,201,98],[33,145,140],[59,82,139],[68,1,84]];
  const s = t * (c.length - 1), i = Math.min(Math.floor(s), c.length - 2), f = s - i;
  return "rgb(" + c[i].map((v, k) => Math.round(v + f * (c[i + 1][k] - v))).join(",") + ")";
}
function poly(d) {
  let s = "", pen = false;
  d.ys.forEach((y, k) => { if (y === null) { pen = false; return; } s += (pen ? "L" : "M") + X(k).toFixed(1) + "," + Y(y).toFixed(1); pen = true; });
  return s;
}
function draw() {
  const g = +gen.value; genv.textContent = g;
  svg.replaceChildren();
  const onPath = new Set(D.path);
  const shown = D.lines.filter(d => d.gen <= g);
  if (!only.checked) for (const d of shown) {
    const p = el("path", {d: poly(d), fill: "none", stroke: color(d.gen), "stroke-width": 1.4, "stroke-opacity": 0.55});
    if (!d.alive) p.setAttribute("stroke-dasharray", "4 3");
    p.addEventListener("mouseenter", () => show(d, p)); svg.append(p);
  }
  const best = shown.filter(d => onPath.has(d.name));
  for (let k = 0; k < best.length; k++) {
    const d = best[k], p = el("path", {d: poly(d), fill: "none", stroke: "var(--path)", "stroke-width": k === best.length - 1 ? 3.2 : 1.8,
                                        "stroke-opacity": 0.35 + 0.65 * (k + 1) / best.length});
    p.addEventListener("mouseenter", () => show(d, p)); svg.append(p);
  }
  D.axes.forEach((a, k) => {
    svg.append(el("line", {x1: X(k), x2: X(k), y1: T, y2: H - B, stroke: "var(--axis)", "stroke-width": 1.5}));
    const t = el("text", {x: X(k), y: H - B + 22, "text-anchor": "middle", fill: "currentColor", "font-size": 13}); t.textContent = a.label; svg.append(t);
    const marks = a.kind === "lista" ? a.names.map((nm, i) => [i / Math.max(a.names.length - 1, 1), nm.split("/").pop().replace(".dat", "").slice(0, 16)])
                                      : [[0, fmt(a.lo)], [1, fmt(a.hi)]];
    for (const [y, s] of marks) { const m = el("text", {x: X(k) + 5, y: Y(y) + 4, fill: "var(--axis)", "font-size": 11}); m.textContent = s; svg.append(m); }
  });
}
function show(d, p) {
  tip.textContent = "nº " + d.index + " · geração " + d.gen + " · " + d.name + (d.alive ? "" : " (parou numa etapa)") + "\\n" +
    D.axes.map((a, k) => a.label + ": " + fmt(d.values[k])).join(" · ") + (D.path.includes(d.name) ? "\\nno caminho da busca" : "");
}
gen.addEventListener("input", draw); only.addEventListener("change", draw); draw();
</script></body></html>
"""


def html(problem: OptProblem, rows: list[dict], title: str = "Caminho da busca") -> str:
    """a página: a figura e o controle das gerações, sem nada de fora (abre sem internet)"""
    return PAGE.replace("__TITLE__", _html.escape(title)).replace("__DATA__", _json(data(problem, rows)))


def write_html(problem: OptProblem, rows: list[dict], path: str, title: str = "Caminho da busca") -> str:
    with open(path, "w", encoding="utf-8") as f:
        f.write(html(problem, rows, title))
    return path
