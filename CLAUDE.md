# atopile × Bazel × Nix

Design PCBs with code (atopile), pinned by Nix, driven by Bazel.

**Read [`rules/atopile-bazel-nix.md`](rules/atopile-bazel-nix.md) first** — it is
the authoritative guide to the toolchain and rules.

## Layout

| Path | What |
|------|------|
| `nix/atopile.nix`, `nix/packages.nix`, `flake.nix` | atopile + kicad-cli as a pinned Nix derivation |
| `bazel/atopile/defs.bzl` | public API: `atopile_project`, `atopile_library` |
| `bazel/atopile/{rules,toolchain,providers}.bzl` | rule impls + toolchain |
| `MODULE.bazel` | rules_nixpkgs wiring; registers the **nix** toolchain (default) + host fallback |
| `examples/blinky/` | worked example (project + library) — builds a real PDF/Gerber offline |

## Quickstart

```bash
nix develop                                  # ato, kicad-cli, bazel on PATH
bazel build //examples/blinky:blinky.gerber   # Gerber manufacturing zip
bazel build //examples/blinky:blinky.pdf      # board layout PDF
bazel run   //examples/blinky:blinky.view     # open in KiCad
bazel run   //examples/blinky:blinky.schematic  # interactive block diagram
```

## Conventions worth not relearning

- Pin the atopile version + `venvHash` in `nix/packages.nix` (the derivation lives
  in `nix/atopile.nix`); keep it in range of each project's `requires-atopile`.
  Re-pin `venvHash` with `venvHash = lib.fakeHash;` → `nix build .#atopile` → paste
  the reported hash. The venv FOD is reproducible, so the pin holds.
- KiCad comes from `kicad-small` on Linux (CLI + no 3D models); on macOS nixpkgs
  KiCad is broken, so atopile uses the **system** `/Applications/KiCad.app`
  `kicad-cli` (see rules doc §9). Footprint `.pretty` libraries come from nix on
  both (`kicad.libraries.footprints`); the atopile derivation bakes a **stock
  `fp-lib-table`** at `<atopile>/share/atopile/stock-fp-lib-table`, which the
  build rules drop into a project's `elec/layout/<build>/fp-lib-table`.
- `venvHash` is **per-platform** (`venvHashBySystem` in `nix/packages.nix`) —
  re-pin each system's entry independently. Verified on aarch64-linux + -darwin.
- Bazel builds run in a private temp copy of the project (no `build/`·`elec/layout`
  written into your checkout); the nix toolchain is split `nix_linux`/`nix_darwin`.
- Two behaviours are patched into the atopile venv (see `nix/atopile.nix`): the
  empty part-pick query no longer hits the network (so all-local designs build
  offline), and the `ato` wrapper sets `OPENSSL_armcap=0` (aarch64 crypto SIGILL
  fix) + `ATO_STOCK_FP_LIB_TABLE`. Build actions also set `HOME` (kicad-cli needs it).
- Give footprint-only parts explicit `component.footprint = "Lib:Name"` (see
  `examples/blinky`), which needs **no** part-picking API. Parameterised stdlib
  parts (`Resistor` + `resistance`) require a picker — see the local picker in
  `tools/atopile-picker/` and rules doc §picking.
- Artifact actions are `local` + `no-sandbox` + `requires-network` on purpose
  (part-picking / registry / EasyEDA footprints). An auto-placed, code-only board
  gets fresh random UUIDs every build, so it is **not** a `--frozen` fixed point:
  the example builds `frozen = False`. Commit + `--frozen` is for layouts you
  hand-place and save in KiCad.
- Commit `elec/layout/**/*.kicad_pcb` only for frozen (hand-placed) projects;
  git-ignore `build/`, `.ato/`, and generated `fp-lib-table`.
- atopile has no schematic sheet (no `.kicad_sch`/`.kicad_pro`): `.pdf` is the
  board layout; `.schematic` is the block-diagram viewer. KiCad's "open
  schematic" button has nothing to show — expected.
- `atopile_project(autoroute = True)` gives the `.pdf` real traces with no human
  in the loop: build twice (push nets) → headless FreeRouting via KiCad's pcbnew
  Python → frame. FreeRouting is pinned to 2.2.4 + a Temurin JRE 25
  (`nix/freerouting.nix`); nixpkgs' 2.1.0 blocks on a GUI dialog. See rules §10.
