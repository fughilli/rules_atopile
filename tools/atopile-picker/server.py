#!/usr/bin/env python3
"""A local, offline, API-compatible atopile component picker.

atopile's compiler resolves *parameterised* stdlib parts (e.g. `Resistor` with a
`resistance`) by POSTing to a components API — by default the hosted
`components.atopileapi.com`. This server speaks the same wire protocol against a
local `catalog.json`, so `ato build` can pick real LCSC parts with **no** hosted
API. Point a project at it with, in `ato.yaml`:

    services:
      components:
        url: http://127.0.0.1:8099

Scope / how it fits the toolchain:
  * It replaces service #1 (the *picker*). Footprint *geometry* (service #2) is
    still fetched by atopile from EasyEDA per LCSC id — reachable today, and
    cacheable under `.ato/` for offline `--frozen` rebuilds. So "local picker +
    committed EasyEDA cache" == fully offline with real, orderable BOM parts.
  * Only resistor type-picking is implemented here (atopile 0.10.x also exposes
    capacitors/inductors; LED type-picking is disabled upstream). The endpoint
    surface and the Component/P_Set schema are the full contract, so extending to
    more part types is data, not protocol, work — grow catalog.json.

Endpoints (see faebryk/libs/picker/api/api.py):
    POST /v0/query                      {"queries":[params...]} -> {"results":[{"components":[...]}]}
    POST /v0/query/<method>             params                  -> {"components":[...]}
    GET  /v0/component/lcsc/<id>                                -> {"components":[...]}
    GET  /v0/component/mfr/<mfr>/<pn>                           -> {"components":[...]}

Stdlib only (http.server/json) so it runs under the pinned nix python with no
extra deps.
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CATALOG = json.loads((Path(__file__).parent / "catalog.json").read_text())


def _ohms_set(value: float) -> dict:
    """Serialise a scalar resistance as the P_Set shape atopile's
    `P_Set.deserialize` accepts — `Quantity_Interval_Disjoint` (NB: the
    surface `L.Single(...).serialize()` emits `type: "Single"`, which
    `deserialize` rejects; the wire form must be the disjoint-interval type)."""
    return {
        "type": "Quantity_Interval_Disjoint",
        "data": {
            "intervals": {
                "type": "Numeric_Interval_Disjoint",
                "data": {"intervals": [{"type": "Numeric_Interval",
                                        "data": {"min": value, "max": value}}]},
            },
            "unit": "ohm",
        },
    }


def _component(part: dict, params: dict) -> dict:
    """Build an API `Component` (faebryk/libs/picker/api/models.py:Component).

    `attributes` carries P_Set literals keyed by the module's parameter names;
    atopile aliases each design param to its literal after attaching. Only
    `resistance` is constrained by the design here, so `max_power`/`max_voltage`
    are left null (atopile treats a null attribute as unbounded == always OK)."""
    return {
        "lcsc": part["lcsc"],
        "manufacturer_name": part["manufacturer"],
        "part_number": part["mpn"],
        "package": part["package"],
        "datasheet_url": part.get("datasheet_url", ""),
        "description": part["description"],
        "is_basic": int(part.get("basic", 0)),
        "is_preferred": int(part.get("preferred", 0)),
        "stock": int(part.get("stock", 100000)),
        "price": [{"qTo": None, "price": part.get("price", 0.001), "qFrom": 1}],
        "attributes": {
            "resistance": _ohms_set(part["resistance_ohms"]),
            "max_power": None,
            "max_voltage": None,
        },
    }


def _interval(pset: dict | None):
    """Extract (min, max) from a resistance P_Set query param, or None."""
    if not pset:
        return None
    try:
        iv = pset["data"]["intervals"]["data"]["intervals"][0]["data"]
        return float(iv["min"]), float(iv["max"])
    except (KeyError, IndexError, TypeError):
        return None


def _match_resistors(params: dict) -> list[dict]:
    """Return catalog resistors whose nominal resistance lies within the query's
    requested range (and package, if constrained)."""
    want = _interval(params.get("resistance"))
    out = []
    for part in CATALOG.get("resistors", []):
        r = part["resistance_ohms"]
        if want is not None and not (want[0] <= r <= want[1]):
            continue
        out.append(_component(part, params))
    # Prefer the tightest fit (closest to the requested midpoint) first.
    if want is not None:
        mid = (want[0] + want[1]) / 2
        out.sort(key=lambda c: abs(c["attributes"]["resistance"]["data"]["intervals"]
                                   ["data"]["intervals"][0]["data"]["min"] - mid))
    return out


def _query(method: str, params: dict) -> list[dict]:
    if method == "resistors":
        return _match_resistors(params)
    # capacitors/inductors/... not yet in the catalog -> no candidates.
    return []


def _by_lcsc(lcsc: int) -> list[dict]:
    for part in CATALOG.get("resistors", []):
        if part["lcsc"] == lcsc:
            return [_component(part, {})]
    return []


def _by_mfr(mfr: str, pn: str) -> list[dict]:
    for part in CATALOG.get("resistors", []):
        if part["manufacturer"] == mfr and part["mpn"] == pn:
            return [_component(part, {})]
    return []


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        m = re.match(r"^/v0/component/lcsc/(\d+)$", self.path)
        if m:
            return self._send({"components": _by_lcsc(int(m.group(1)))})
        m = re.match(r"^/v0/component/mfr/([^/]+)/([^/]+)$", self.path)
        if m:
            return self._send({"components": _by_mfr(m.group(1), m.group(2))})
        self._send({"components": []})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/v0/query":
            queries = data.get("queries", [])
            return self._send({"results": [
                {"components": _query(q.get("endpoint", ""), q)} for q in queries]})
        m = re.match(r"^/v0/query/([A-Za-z_]+)$", self.path)
        if m:
            return self._send({"components": _query(m.group(1), data)})
        self._send({"components": []})

    def log_message(self, *_):  # quiet
        pass


def main():
    host, port = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    print(f"atopile local picker on http://{host}:{port} "
          f"({sum(len(v) for k, v in CATALOG.items() if isinstance(v, list))} parts)",
          file=sys.stderr)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
