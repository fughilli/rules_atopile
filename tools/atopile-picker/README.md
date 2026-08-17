# Local atopile picker

An offline, API-compatible replacement for atopile's hosted component-picking
service (`components.atopileapi.com`). It lets `ato build` resolve **parameterised
stdlib parts** — `Resistor` with a `resistance` + `package`, etc. — to real LCSC
parts from a local `catalog.json`, with no hosted API.

## Why this exists — the two services

atopile's picking involves **two** independent network services:

1. **The picker** (`components.atopileapi.com`) — matches a design's constraints
   to a part and returns an **LCSC id**. This server replaces it.
2. **EasyEDA** (`easyeda.com`, via `easyeda2kicad`) — given that LCSC id, atopile
   downloads the actual **footprint/symbol/3D geometry**. This server does *not*
   replace it; atopile still fetches from EasyEDA.

So a local picker alone is **not** fully offline. The offline story is *local
picker + committed EasyEDA cache*: build once online (EasyEDA is reachable), then
commit atopile's cached footprints so `--frozen` rebuilds need no network. Parts
that carry an **explicit** `component.footprint` (see `examples/blinky`) skip both
services and are offline today — that's the other end of the trade-off.

## Use it

```bash
# 1. start the picker (stdlib-only; runs under the pinned nix python)
python tools/atopile-picker/server.py 8099

# 2. point a project's ato.yaml at it
#    services:
#      components:
#        url: http://127.0.0.1:8099

# 3. build — parameterised parts now resolve to real LCSC parts
bazel build //examples/picker_demo   # or: ato build -b default
```

`examples/picker_demo` is a worked example: a bare `Resistor` (`150ohm ±5%`,
`0402`) that the picker resolves to **C25082** (UNI-ROYAL 0402WGF1500TCE), which
lands in the BOM.

## The wire contract

Endpoints (from `faebryk/libs/picker/api/api.py`):

| Method + path | Response |
|---|---|
| `POST /v0/query` `{"queries":[params…]}` | `{"results":[{"components":[…]}]}` |
| `POST /v0/query/<method>` `params` | `{"components":[…]}` |
| `GET  /v0/component/lcsc/<id>` | `{"components":[…]}` |
| `GET  /v0/component/mfr/<mfr>/<pn>` | `{"components":[…]}` |

A `Component`'s `attributes` map carries **P_Set literals** keyed by the module's
parameter names; atopile aliases each design parameter to its literal, then the
solver checks compatibility. The one non-obvious detail: the wire form of a scalar
must be **`Quantity_Interval_Disjoint`** — the surface `L.Single(x).serialize()`
emits `type: "Single"`, which `P_Set.deserialize` *rejects*. `_ohms_set()` in
`server.py` emits the accepted shape.

## Growing the catalog

`catalog.json` is a hand-curated slice (a few resistors). To scale to the whole
JLCPCB catalog, generate entries from the published **jlcparts** database
(`resistance_ohms`, `package`, `lcsc`, `mpn`, …) — the schema here is the target.
Only resistor type-picking is wired up (atopile 0.10.x also exposes
capacitors/inductors; LED type-picking is disabled upstream), so more part types
are catalog + a `_match_*` function, not protocol work.
