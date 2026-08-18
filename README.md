# rules_atopile

Design PCBs with code — [atopile](https://atopile.io) compiled by **Bazel**,
pinned by **Nix**.

You write your board in `.ato` (parts by LCSC id, connections as code); Bazel
builds it hermetically against a Nix-pinned `ato` + `kicad-cli`, and produces a
board layout, a PDF, and Gerbers — offline, no local toolchain install.

## Quickstart

```bash
nix develop                                   # ato, kicad-cli, bazel on PATH
bazel build //examples/blinky:blinky          # pick + lay out -> resolved .kicad_pcb
bazel build //examples/blinky:blinky.pdf      # board layout PDF   (kicad-cli)
bazel build //examples/blinky:blinky.gerber   # Gerber + drill dir (kicad-cli)
bazel run   //examples/blinky:blinky.view     # open the layout in KiCad
```

## What you get

`atopile_project(name = "…")` fans out a family of targets:

| Target | Output |
|--------|--------|
| `//pkg:name` | pick parts + lay out → resolved `.kicad_pcb` |
| `.pdf` | board layout PDF |
| `.gerber` | Gerber + Excellon drill (fab directory) |
| `.bom` / `.glb` / `.step` / `.svg` / `.png` | BOM + 3D/2D renders |
| `.view` / `.schematic` | open in KiCad / serve the block diagram |

**Network is scoped to one action.** Only the base `//pkg:name` step touches the
network (part-picking + footprint fetch); it emits a self-contained
`.kicad_pcb`, and `.pdf`/`.gerber` are then pure `kicad-cli` — hermetic, no
network.

## Layout

| Path | What |
|------|------|
| `nix/`, `flake.nix` | atopile + kicad-cli as a pinned Nix derivation |
| `bazel/atopile/` | the rules — `atopile_project`, `atopile_library` |
| `tools/atopile-picker/` | local, API-compatible parts picker (runs as a build sidecar) |
| `examples/blinky/` | worked example — a real board, built offline |
| `MODULE.bazel` | Nix toolchain wiring (via rules_nixpkgs) |

See [`CLAUDE.md`](CLAUDE.md) and [`rules/atopile-bazel-nix.md`](rules/atopile-bazel-nix.md)
for the details.
