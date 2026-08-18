"""Public API for building atopile projects with Bazel.

    load("//bazel/atopile:defs.bzl", "atopile_project", "atopile_library")

`atopile_project` declares a design and fans out a family of sub-targets:

    //pkg:name            `ato build`  — verify the design compiles/builds
    //pkg:name.view       bazel run    — open the layout in the KiCad editor
    //pkg:name.schematic  bazel run    — serve the interactive block diagram
    //pkg:name.pdf        bazel build  — board layout -> PDF (via kicad-cli)
    //pkg:name.gerber     bazel build  — Gerber manufacturing zip (ato mfg-data)
    //pkg:name.bom        bazel build  — bill of materials CSV
    //pkg:name.glb        bazel build  — 3D PCBA model (.glb)
    //pkg:name.step       bazel build  — 3D PCBA model (.step)
    //pkg:name.svg        bazel build  — 2D board render (.svg)
    //pkg:name.png        bazel build  — 3D board render (.png)

`atopile_library` wraps atopile's reusable `module`/`component` concept so
designs can share components across packages via `deps`.
"""

load(
    ":rules.bzl",
    "atopile_artifact",
    "atopile_build",
    "atopile_pdf",
    "atopile_run",
)
load(":rules.bzl", _atopile_library = "atopile_library")

# Re-export the library rule under its public name.
atopile_library = _atopile_library

# (atopile build target, output filename suffix, source artifact suffix).
_ARTIFACTS = [
    ("gerber", "mfg-data", ".gerber.zip", ".gerber.zip"),
    ("bom", "bom", ".bom.csv", ".bom.csv"),
    ("glb", "glb", ".glb", ".pcba.glb"),
    ("step", "step", ".step", ".pcba.step"),
    ("svg", "2d-image", ".svg", ".pcba.svg"),
    ("png", "3d-image", ".png", ".pcba.png"),
]

def atopile_project(
        name,
        ato_yaml = "ato.yaml",
        srcs = None,
        build = "default",
        deps = [],
        frozen = True,
        outline_margin_mm = 0,
        autoroute = False,
        picker = False,
        visibility = None,
        tags = []):
    """Declare an atopile project and its build/export/view sub-targets.

    Args:
      name: base target name; sub-targets are `name.<kind>`.
      ato_yaml: the project manifest (default `ato.yaml` in this package).
      srcs: design sources; defaults to all `*.ato`/`*.py` under this package.
      build: the build config to select (`ato build -b <build>`).
      deps: `atopile_library` targets whose modules this design imports.
      frozen: pass `--frozen` (forbid layout mutation) to artifact builds.
      outline_margin_mm: if > 0, the `.pdf` target frames an auto-placed board
        with an Edge.Cuts outline + tight page (this mm margin) so the export
        isn't a near-blank A4 sheet. For hand-outlined boards leave it 0.
      autoroute: if True, the `.pdf` target runs a headless FreeRouting pass over
        the placed board (via KiCad's pcbnew Python) so it has traces — a fully
        no-human end-to-end flow. Pulls `@freerouting`. See tools/autoroute.py.
      visibility: standard Bazel visibility.
      tags: extra tags applied to every generated target.
    """
    if srcs == None:
        srcs = native.glob(["**/*.ato", "**/*.py"], allow_empty = True)

    common = dict(
        ato_yaml = ato_yaml,
        srcs = srcs,
        deps = deps,
        build = build,
        picker = picker,
        # nix python3 to run the picker sidecar; only referenced (fetched) when
        # picking is on.
        picker_python = "@python3//:bin/python3" if picker else None,
        visibility = visibility,
        tags = tags,
    )

    # Base target: does the design build?
    atopile_build(name = name, frozen = frozen, **common)

    # Interactive targets (bazel run). `args_` is atopile's argv.
    _run_common = dict(ato_yaml = ato_yaml, srcs = srcs, deps = deps, build = build, visibility = visibility, tags = tags)
    atopile_run(
        name = name + ".view",
        args_ = ["build", "-b", build, "--open"],
        **_run_common
    )
    # 0.15.x has no standalone diagram viewer; `ato serve core` starts the
    # backend the atopile IDE/web app (app.atopile.io, VS Code extension) connect
    # to for the block-diagram/inspect view.
    atopile_run(
        name = name + ".schematic",
        args_ = ["serve", "core"],
        **_run_common
    )

    # File-producing export targets (bazel build). Outputs land under
    # `<name>.out/` so file names never collide with the rule names above.
    outdir = name + ".out/" + name
    for kind, target, out_suffix, src_suffix in _ARTIFACTS:
        atopile_artifact(
            name = name + "." + kind,
            target = target,
            out = outdir + out_suffix,
            src_suffix = src_suffix,
            frozen = frozen,
            **common
        )

    # Board layout PDF (kicad-cli; atopile has no schematic sheet — see docs).
    # `freerouting` is set only when autoroute is on, so @freerouting isn't
    # fetched otherwise.
    atopile_pdf(
        name = name + ".pdf",
        out = outdir + ".pdf",
        frozen = frozen,
        outline_margin_mm = outline_margin_mm,
        autoroute = autoroute,
        freerouting = "@freerouting//:bin/freerouting" if autoroute else None,
        **common
    )
