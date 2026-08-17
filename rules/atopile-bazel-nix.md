# Rules for working with atopile in Bazel + Nix

This repo packages [atopile](https://atopile.io) (design PCBs with code) as a Nix
derivation and drives it through Bazel rules. The goal: **one command per
artifact**, reproducible toolchain, and reusable components.

```
Nix  ──> pins `ato` + `kicad-cli`            (nix/, flake.nix)
Bazel ──> toolchain + rules + sub-targets     (bazel/atopile/)
You  ──> atopile_project / atopile_library    (examples/blinky/BUILD.bazel)
```

---

## 1. The Nix layer — bringing atopile in

atopile is a Python app whose dependency closure (faebryk, atopile-kicad-python,
shapely, numpy, fastapi…) is **not** in nixpkgs, and it shells out to
`kicad-cli` for **every** export. So:

- `nix/atopile.nix` resolves the whole closure with `uv` inside a **fixed-output
  derivation** (the only step allowed network), then wraps `ato` with
  `kicad-cli` on `PATH`. The FOD's `venvHash` pins the resolved tree ⇒ same
  atopile version → same hash → reproducible.
- `nix/packages.nix` is the single source of truth (`{ atopile, kicad }`),
  imported by both the flake and Bazel.
- `flake.nix` exposes `packages.atopile`, `packages.kicad`, and a `devShell`
  with `ato`, `kicad-cli`, and `bazelisk`.

**Rule: pin the version in exactly one place.** `version` lives in
`nix/atopile.nix` (default `0.10.23`, Python 3.13). To bump it:

```bash
# 1. edit `version` in nix/atopile.nix
# 2. force a re-pin: set `venvHash = lib.fakeHash;` in nix/packages.nix
nix build .#atopile            # prints "got: sha256-…"
# 3. paste that hash into nix/packages.nix's `venvHash` and commit
```

The venv is a **reproducible, reference-free** fixed-output derivation, so
`venvHash` pins cleanly (a determinism pass in `nix/atopile.nix` strips the
sdist build-path/build-id nondeterminism, removes the self-referential
`#!$out/bin/python` shebangs, and scrubs the `/nix/store` RUNPATH entries an FOD
may not carry; the outer wrapper re-supplies them at runtime). The pin is
per-version **and** per-platform (aarch64-linux here).

Keep the pinned version aligned with each project's `requires-atopile` in
`ato.yaml`.

**Rule: enter the shell before doing anything.**

```bash
nix develop            # -> ato, kicad-cli, bazel on PATH
```

---

## 2. The Bazel layer — toolchains

Every atopile rule resolves `//bazel/atopile:toolchain_type`. There are two
interchangeable implementations:

| Toolchain | `ato` / `kicad-cli` from | Hermetic? | Use when |
|-----------|--------------------------|-----------|----------|
| **nix** (default) | rules_nixpkgs `@atopile` (+ `@kicad` on Linux) | yes | build/export artifacts — no `nix develop` needed |
| **host** (fallback) | `PATH` (the `nix develop` shell) | no | interactive `bazel run …:*.view` / `.schematic` |

`MODULE.bazel` wires `rules_nixpkgs` and registers the **nix** toolchain first,
so artifact actions get `ato`/`kicad-cli` as concrete `/nix/store` paths without
a `nix develop` PATH. nixpkgs is pinned there to the **same commit as
`flake.lock`** (the atopile derivation and its `venvHash` are keyed to that
nixpkgs' `python313`; a floating tag risks a `venvHash` mismatch) — update the
`commit` in `MODULE.bazel` and `flake.lock` together. The **host** toolchain
stays registered as a fallback and is what the `.view`/`.schematic` run targets
use (they invoke `ato` from PATH by design).

**The nix toolchain is split by exec platform** (`bazel/atopile/nix:BUILD.bazel`):
`nix_linux` sources `kicad-cli` from `@kicad`; `nix_darwin` does **not** reference
`@kicad` (nixpkgs marks the KiCad *application* broken on aarch64-darwin) and
instead calls the **system** `/Applications/KiCad/KiCad.app` `kicad-cli`.
`exec_compatible_with` selects the right one and keeps `@kicad` out of the macOS
build graph. See §9 for the full macOS story.

> Notes: (1) the nix toolchain provides `ato` as an execroot-relative path, so
> the rules bind it to `$ATO` (absolutized) up front — see `_ato_setup`. (2) Each
> artifact action builds in a **private temp copy** of the project (`_root_setup`)
> rather than the source tree, so concurrent targets don't race and no
> `build/`·`elec/layout` junk lands in your checkout.

**Rule: atopile build actions are `local` + `no-sandbox` + `requires-network`.**
This is deliberate — part-picking calls a components API, dep resolution hits the
registry, and picked footprints are fetched from EasyEDA, so the actions can't be
sandboxed. Bazel still caches by inputs and collects the declared outputs; the
pinned `ato` (Nix) is what makes the toolchain reproducible.

**On `--frozen`:** atopile stamps *fresh random UUIDs* into the layout on every
build, so an auto-placed, code-only board is **never** a byte-for-byte `--frozen`
fixed point — the examples build `frozen = False` (regenerate the layout from
`.ato` each build). `--frozen` is for layouts you **hand-place and save in
KiCad** (`bazel run …:blinky.view`), which get stable UUIDs; commit that
`.kicad_pcb` and set `frozen = True`.

---

## 3. `atopile_project` — a design and its sub-targets

```python
load("//bazel/atopile:defs.bzl", "atopile_project")

atopile_project(
    name = "blinky",
    srcs = ["elec/src/blinky.ato"],   # default: glob **/*.ato, **/*.py
    ato_yaml = "ato.yaml",            # default: ato.yaml in this package
    build = "default",                # the ato.yaml build config (ato build -b)
    deps = [":indicator"],            # atopile_library targets
    frozen = False,                   # True only for hand-placed committed layouts (§2)
)
```

One call fans out into these sub-targets (`name.<kind>`):

| Sub-target | Bazel verb | Under the hood | Output |
|------------|-----------|----------------|--------|
| `blinky` | `build` | `ato build -b default` | build marker (design compiles) |
| `blinky.view` | **run** | `ato build -b default --open` | opens the **KiCad** PCB editor |
| `blinky.schematic` | **run** | `ato view -b default --serve` | serves the interactive block diagram |
| `blinky.pdf` | `build` | `ato build` + `kicad-cli pcb export pdf` (from `elec/layout/<b>/<b>.kicad_pcb`) | `blinky.out/blinky.pdf` (board layout) |
| `blinky.gerber` | `build` | `ato build -t mfg-data` | `blinky.out/blinky.gerber.zip` |
| `blinky.bom` | `build` | `ato build -t bom` | `blinky.out/blinky.bom.csv` |
| `blinky.glb` | `build` | `ato build -t glb` | `blinky.out/blinky.glb` (3D) |
| `blinky.step` | `build` | `ato build -t step` | `blinky.out/blinky.step` (3D) |
| `blinky.svg` | `build` | `ato build -t 2d-image` | `blinky.out/blinky.svg` |
| `blinky.png` | `build` | `ato build -t 3d-image` | `blinky.out/blinky.png` |

```bash
bazel run   //examples/blinky:blinky.view       # open in KiCad
bazel build //examples/blinky:blinky.gerber      # -> bazel-bin/.../blinky.out/blinky.gerber.zip
bazel build //examples/blinky:blinky.pdf //examples/blinky:blinky.bom
```

**On PDF / "schematic":** atopile is code-first and has **no KiCad schematic
sheet** (`.kicad_sch`), so `.pdf` exports the **board layout** to PDF via
`kicad-cli` (layers configurable in `//bazel/atopile:rules.bzl`). The nearest
thing to a schematic is the interactive block diagram — that's `.schematic`
(`ato view --serve`).

**Adding a new export target** = one row in `_ARTIFACTS` in
`bazel/atopile/defs.bzl` (atopile target name + output suffix + source suffix).
Valid atopile targets: `bom`, `glb`, `step`, `2d-image`, `3d-image`,
`mfg-data`, `manifest`, `variable-report`, `power-tree`, `datasheets`, `all`.
Output file suffixes follow `build/builds/<b>/<b>.<suffix>` (e.g. gerber →
`.gerber.zip`, glb → `.pcba.glb`, step → `.pcba.step`, 2d → `.pcba.svg`).

---

## 4. `atopile_library` — reusable components

Wraps atopile's `module` / `component` concept as a Bazel target so designs
share components via `deps`:

```python
load("//bazel/atopile:defs.bzl", "atopile_library")

atopile_library(
    name = "indicator",
    srcs = ["elec/src/indicator.ato"],   # defines `module IndicatorLed:`
    import_name = "example/indicators",  # informational package identifier
    deps = [],                           # other atopile_library targets
    visibility = ["//visibility:public"],
)
```

It emits `AtopileLibraryInfo` carrying `transitive_srcs` + `manifests`, so an
`atopile_project` that lists it in `deps` gets those `.ato` files as build
inputs and dependency edges (rebuilds when a shared module changes).

**Rule: keep a library's `.ato` inside the consuming project's tree.** atopile
resolves `from "elec/src/indicator.ato" import IndicatorLed` **relative to the
project root**, so path-imported libraries must live under that project (as in
`examples/blinky`). For cross-repo/registry reuse, add a `package:` block to the
library's `ato.yaml` and publish it, then consume via `ato add` — the Bazel
`deps` edge is for in-repo reuse and dependency tracking, not a substitute for
atopile's package registry.

---

## 5. Project conventions (`ato.yaml` + layout)

```yaml
requires-atopile: ">=0.10.0,<0.11.0"   # keep in range of the Nix-pinned version
builds:
  default:
    entry: elec/src/blinky.ato:Blinky   # <file>:<Module>
```

- Default paths (from atopile): source `elec/src/`, layout `elec/layout/<build>/`,
  outputs `build/builds/<build>/`.
- **Commit the layout** (`elec/layout/**/*.kicad_pcb`) **only for `frozen = True`
  projects** — i.e. once you hand-place and save it in KiCad (§2). Code-only
  auto-placed boards (`frozen = False`) regenerate the layout each build, so
  don't commit it.
- `build/`, `.ato/`, and the generated `fp-lib-table` are build artifacts — keep
  them git-ignored (already in `.gitignore`).

---

## 6. Picking components — the two services

Producing a board needs every component mapped to a real **footprint**. There are
**two independent** ways to get there, and two network services behind the
hosted path:

1. **The picker API** (`components.atopileapi.com` — dead/NXDOMAIN;
   `legacy.atopileapi.com` — up but auth-gated) matches a *parameterised* part
   (`Resistor` + `resistance` + `package`) and returns an **LCSC id**.
2. **EasyEDA** (`easyeda.com`, via `easyeda2kicad`) turns that LCSC id into the
   actual **footprint geometry**. The picker only ever returns an id; geometry
   always comes from EasyEDA.

This repo supports both ends of the trade-off:

- **Explicit local footprints (offline today).** Give a `component` an explicit
  `footprint = "Lib:Name"` (see `examples/blinky`'s `indicator.ato`). No picker,
  no EasyEDA — the identifier resolves against the project `fp-lib-table` (§7),
  and the footprint is read from KiCad's bundled libraries and embedded into the
  `.kicad_pcb`. Trade-off: no orderable BOM part number.
- **Local picker (real parts, EasyEDA for geometry).** `tools/atopile-picker`
  is an offline, API-compatible replacement for service #1, backed by a local
  `catalog.json` of real LCSC parts. Point a project at it in `ato.yaml`
  (`services: { components: { url: http://127.0.0.1:8099 } }`) and parameterised
  stdlib parts resolve to real parts — see `examples/picker_demo` (a `Resistor`
  → **C25082**, which lands in the BOM). atopile still fetches the *footprint*
  from EasyEDA (reachable today); commit atopile's EasyEDA cache for offline
  `--frozen` rebuilds. This is the path to "fully local with real BOM parts".

atopile 0.10.x type-picks resistors/capacitors/inductors; **LED type-picking is
disabled upstream**, so LEDs always need an explicit footprint or `lcsc_id`.

## 7. Verification status (2026-08-17)

Everything below is exercised end-to-end on aarch64-linux:

- **`nix build .#atopile`** is reproducible; `venvHash` (in `nix/packages.nix`)
  pins cleanly. KiCad is `kicad-small` (CLI, no 3D models); its footprint
  libraries come from `kicad.libraries.footprints`, from which the derivation
  bakes a stock `fp-lib-table` at `<atopile>/share/atopile/stock-fp-lib-table`.
- **`bazel build //examples/blinky:blinky.pdf`** produces a real 1-page PDF, and
  `:blinky.gerber` a Gerber zip — via the **nix** toolchain, fully offline (no
  picker, explicit footprints). The rules seed the project `fp-lib-table` from
  the stock table, set `HOME` (kicad-cli requires it), and the `ato` wrapper sets
  `OPENSSL_armcap=0` (fixes the aarch64 `cryptography`-wheel SIGILL) — no
  `--action_env` needed.
- **`examples/picker_demo`** builds against the local picker: a bare `Resistor`
  is resolved to a real LCSC part offline, footprint fetched from EasyEDA.
- Two behaviours are **patched into the atopile venv** (`nix/atopile.nix`, re-pin
  `venvHash` if you change them): the empty part-pick query no longer hits the
  network (all-local designs build offline), and `ato` is wrapped with
  `OPENSSL_armcap=0` + `ATO_STOCK_FP_LIB_TABLE`.

### Footprint resolution (`fp-lib-table`)

An explicit `component.footprint = "Lib:Name"` resolves **only** against the
project's `elec/layout/<build>/fp-lib-table` — atopile does *not* consult KiCad's
global table. The build rules copy the toolchain's stock table there before each
build (it embeds `/nix/store` URIs, so it's **git-ignored**). The `ato` binary
also exports `$ATO_STOCK_FP_LIB_TABLE` for local `ato build` outside Bazel.

---

## 8. Layout nondeterminism and the spirit of `--frozen`

The examples build `frozen = False` because an atopile-generated layout is **not a
byte-stable fixed point** — regenerating it changes the file even when the design
didn't. This is worth understanding before reaching for `--frozen`.

### What `--frozen` is for

`--frozen` is a **code↔layout drift guard**. atopile derives the *netlist*
(components + connectivity) from the `.ato`; the `.kicad_pcb` holds *physical
placement/routing*. Frozen fails the build if regenerating the layout would change
it. That is only meaningful when the layout is **human-curated** — i.e. you have
hand-placed/routed the board in KiCad (`bazel run …:foo.view`), which atopile
can't reproduce. Then frozen (a) stops a rebuild from clobbering your placement,
and (b) catches an `.ato` edit that drifts from the committed board. For an
auto-placed, code-only board there is nothing curated to protect, and electrical
reproducibility already comes from the pinned toolchain + the deterministic
*netlist* — so frozen's byte comparison guards a distinction that carries no
electrical or physical meaning.

### Why the bytes churn (≥3 sources, verified against 0.10.23)

1. **`gen_uuid()` = `uuid.uuid4()`** (`faebryk/libs/kicad/fileformats_common.py`)
   — every PCB element gets a fresh random UUID each build.
2. **`_hash_lib_fp()` is order-nondeterministic** — the `__atopile_lib_fp_hash__`
   property is `blake2b(repr(asdict(fp)))`, and that `repr` embeds set/dict
   ordering that varies with `PYTHONHASHSEED`, so the hash value churns even for
   an identical footprint.
3. **Serialization isn't idempotent** — a regenerated PCB was observed adding /
   reordering top-level `(net …)` declarations vs. the just-written one.

The footprint **reuse** path exists (`PCB_Transformer.map_footprints` matches a
committed footprint to a design node by its `atopile_address` property), but even
on a match, `update_footprint_from_lib → _set_lib_fp_hash` **re-stamps a fresh
`gen_uuid`** into the hash property every build — so a committed layout churns
even when it is genuinely reused.

### Approaches to achieving frozen's *spirit* here

Ordered roughly by effort; we ship (1) and note the rest as candidates.

1. **`frozen = False` + trust the netlist (current).** Reproducibility = pinned
   `ato`/toolchain + deterministic electrical netlist. UUID churn is cosmetic.
   Simple and honest; the cost is you can't byte-diff a committed `.kicad_pcb`.
2. **Semantic (netlist-level) frozen.** Instead of byte-comparing the PCB, commit
   and diff a *normalized* artifact — the derived netlist, or the PCB with UUIDs
   masked. A rule that fails on netlist drift delivers frozen's actual value (a
   code↔layout drift guard) without fighting UUIDs. This is the most attractive
   next step and stays entirely in *our* rules (no atopile patch).
3. **Deterministic-UUID venv patch.** Replace `uuid4` with a content/path-derived
   scheme (a bare counter also needs `PYTHONHASHSEED` pinned, since call *order*
   is itself nondeterministic — see source 2), make `_hash_lib_fp` order-
   independent, and stop re-stamping the hash-property UUID. This makes real
   `--frozen` viable, but it is a multi-front patch in a moving upstream (re-pin
   `venvHash` each bump; risk of UUID collisions / KiCad confusion). Best pursued
   as an **upstream issue/PR**, not a local fork. The narrowest useful slice is
   just the *reuse-path* fix (sources 2 + the re-stamp) so a hand-placed layout
   round-trips.
4. **Hand-placed workflow.** Place/route in KiCad, commit the `.kicad_pcb`, set
   `frozen = True`. This is frozen's intended use; note it may still need the
   source-2 / re-stamp fix from (3) before a KiCad-saved layout round-trips
   cleanly — verify before relying on it in CI.

---

## 9. Platforms (Linux + macOS)

Verified on **aarch64-linux** and **aarch64-darwin** (Apple Silicon). The one
real cross-platform wrinkle is KiCad on macOS:

- **nixpkgs marks the KiCad *application* broken on aarch64-darwin** (a
  long-standing macOS build issue), so `nix/packages.nix` sets `kicad = null`
  there. The atopile derivation then does **not** put a nixpkgs `kicad-cli` on
  its wrapper PATH; atopile's own `find_kicad_cli` locates the **system**
  `/Applications/KiCad/KiCad.app` instead (install it, e.g. `brew install --cask
  kicad`). On Linux, `kicad = kicad-small` as before.
- **Footprints still come from nix on both platforms.** `kicad.libraries.
  footprints` is a *separate, non-broken* data package, so the stock
  `fp-lib-table` is identical everywhere. (Its `.pretty` dirs sit under
  `share/kicad/footprints/` on Linux but `footprints/` on macOS — the generator
  `find`s them rather than hardcoding a path.)
- **`venvHash` is per-platform** (`venvHashBySystem` in `nix/packages.nix`): the
  venv compiles any wheels PyPI doesn't ship, so the resolved tree differs by
  system. Re-pin each platform's entry independently.
- **The venv determinism pass is Linux-only.** `objcopy`/`patchelf` are ELF
  tools; on macOS they corrupt Mach-O dylibs (drop `LC_ID_DYLIB`, break
  code-signing). nixpkgs ships signed, self-contained wheels there, so the
  extensions are left untouched.
- **Bazel:** the `nix_darwin` toolchain uses the system `kicad-cli` and never
  fetches `@kicad` (see §2). Everything else — `@atopile`, the stock table, the
  isolated build dir — is identical across platforms.

macOS build once online (EasyEDA reachable); nothing here needs the broken
nixpkgs KiCad app.
