"""Rule implementations behind the `atopile_project` / `atopile_library` macros.

atopile builds are not naturally hermetic: part-picking calls the JLCPCB API and
dependency resolution hits the package registry. So the artifact rules run as
`local`, `requires-network` actions — Bazel orchestrates, caches by inputs, and
collects the declared outputs, while reproducibility comes from (a) a pinned
`ato` (the Nix derivation), (b) a committed KiCad layout, and (c) `--frozen`,
which forbids atopile from mutating that layout mid-build.
"""

load(":providers.bzl", "AtopileLayoutInfo", "AtopileLibraryInfo", "AtopileProjectInfo", "AtopileToolchainInfo")

TOOLCHAIN_TYPE = "//bazel/atopile:toolchain_type"

# atopile writes every artifact for build `<b>` to build/builds/<b>/<b>.<suffix>
# (output_base == build/builds/<b>/<b>). See atopile/config.py:BuildTargetPaths.
_OUTPUT_DIR = "build/builds/{build}"
_OUTPUT_BASE = _OUTPUT_DIR + "/{build}"

def _toolchain(ctx):
    return ctx.toolchains[TOOLCHAIN_TYPE].atopileinfo

def _ato_cmd(info):
    return info.ato.path if info.ato else info.ato_path

def _kicad_cmd(info):
    return info.kicad_cli.path if info.kicad_cli else info.kicad_cli_path

def _tool_inputs(info):
    extra = []
    if info.ato:
        extra.append(info.ato)
    if info.kicad_cli:
        extra.append(info.kicad_cli)
    return depset(direct = extra, transitive = [info.runfiles])

def _project_inputs(ctx, info):
    """All files an action needs: sources, manifest, deps and the toolchain."""
    transitive = [dep[AtopileLibraryInfo].transitive_srcs for dep in ctx.attr.deps]
    transitive.append(_tool_inputs(info))
    return depset(
        direct = ctx.files.srcs + [ctx.file.ato_yaml],
        transitive = transitive,
    )

def _path_export(info):
    # Ensure `kicad-cli` is discoverable by `ato` (it shells out by bare name),
    # by prepending the directory of the resolved kicad-cli to PATH.
    if info.kicad_cli:
        return 'export PATH="$(cd "$(dirname \'{kc}\')" && pwd):$PATH"'.format(kc = info.kicad_cli.path)
    return ""

def _ato_setup(info):
    # Bind `$ATO` to the atopile command once, at the top of the action (cwd ==
    # execroot). The nix toolchain provides `ato` as an execroot-relative File
    # path, which would break after the later `cd "$ROOT"`; resolve it to an
    # absolute path here so it survives. The host toolchain's `ato` is a bare
    # command on PATH, used verbatim.
    cmd = _ato_cmd(info)
    if info.ato:
        return 'ATO="$(cd "$(dirname \'{c}\')" && pwd)/$(basename \'{c}\')"'.format(c = cmd)
    return 'ATO="{c}"'.format(c = cmd)

def _home_export():
    # kicad-cli refuses to run without $HOME ("Environment variable HOME is
    # empty. Unable to continue."), and atopile shells out to it (mfg-data,
    # pdf export). Bazel actions run with HOME unset, so give it a writable
    # dir. A per-action temp dir keeps builds from sharing KiCad state.
    return 'export HOME="${HOME:-$(mktemp -d)}"'

def _root_setup(ctx):
    # Build in a PRIVATE COPY of the project rather than in the source tree.
    # These actions are `no-sandbox` (they need the network + the host nix), so
    # without this every `ato build` would write build//elec/layout into the
    # user's checkout AND concurrent sibling targets (e.g. .pdf and .gerber)
    # would race on the same layout dir. Copy the project into a per-action temp
    # dir and build there. `cp -RL` dereferences the execroot's source symlinks
    # into real files; `$ROOT` is the isolated copy everything below operates on.
    return "\n".join([
        'SRC="$(cd "$(dirname "{ay}")" && pwd)"'.format(ay = ctx.file.ato_yaml.path),
        'ROOT="$(mktemp -d)"',
        # Copy each top-level entry EXCEPT the generated build/ and .ato dirs:
        # a prior `ato build`/`.view` run in the source tree leaves atopile's
        # dangling `build/logs/latest` symlink, which `cp -RL` (dereference)
        # can't stat. `-RL` resolves the execroot's source symlinks to real
        # files; the fallback keeps symlinks if a stray dangling one remains.
        "( shopt -s dotglob nullglob; for _e in \"$SRC\"/*; do " +
        "case \"$(basename \"$_e\")\" in build|.ato) continue ;; esac; " +
        "cp -RL \"$_e\" \"$ROOT\"/ 2>/dev/null || cp -R \"$_e\" \"$ROOT\"/; done )",
        # Copied files inherit the execroot's read-only perms (nix store), but
        # atopile 0.15.x WRITES into the tree (fp-lib-table, ingested parts), so
        # make the private copy writable.
        'chmod -R u+w "$ROOT" 2>/dev/null || true',
    ])

def _fp_table_setup(ctx):
    # Seed the project fp-lib-table so explicit `component.footprint` ids resolve
    # (atopile does not consult KiCad's global table). Copy the stock table the
    # atopile derivation ships at <atopile>/share/atopile/stock-fp-lib-table,
    # located relative to the resolved `ato` (`$ATO`) rather than as a Bazel
    # input — rules_nixpkgs' generated BUILD only exposes bin/lib/include, and
    # these actions are `local`/`no-sandbox`, so the store path is readable
    # directly. Works for both toolchains (nix: $ATO is an absolute store path;
    # host: `command -v` resolves the devShell wrapper). atopile's default layout
    # path is elec/layout/<build>/.
    layout_dir = "elec/layout/{build}".format(build = ctx.attr.build)
    return "\n".join([
        'mkdir -p "$ROOT/{ld}"'.format(ld = layout_dir),
        '_ato_real="$(readlink -f "$(command -v "$ATO")")"',
        '_fp_tbl="$(dirname "$(dirname "$_ato_real")")/share/atopile/stock-fp-lib-table"',
        # cp then chmod: the stock table is read-only (nix store) but atopile
        # 0.15.x rewrites the project fp-lib-table while picking.
        'if [ -f "$_fp_tbl" ]; then cp -f "$_fp_tbl" "$ROOT/{ld}/fp-lib-table"; chmod u+w "$ROOT/{ld}/fp-lib-table"; fi'.format(ld = layout_dir),
    ])

def _autoroute_step(ctx, pcb):
    # Optional headless autorouting (opt in via `autoroute`): run FreeRouting
    # over the placed board via KiCad's pcbnew Python (DSN out -> route -> SES
    # in), so the exported board actually has traces — see tools/autoroute.py.
    # Returns (shell, [extra input Files]). KiCad's autorouter *is* FreeRouting,
    # and only KiCad's own Python has the Specctra DSN/SES bindings (kicad-cli /
    # kicad-small don't), so we resolve a pcbnew-capable interpreter at action
    # time: $KICAD_PYTHON, the system KiCad.app (macOS), then a plain python3
    # (Linux w/ a full nixpkgs kicad). `no-sandbox` lets those resolve.
    if not ctx.attr.autoroute or not ctx.file.freerouting:
        return "", []
    fr = ctx.file.freerouting
    ap = ctx.file._autoroute
    lines = [
        "_FR=\"$(cd \"$(dirname '%s')\" && pwd)/$(basename '%s')\"" % (fr.path, fr.path),
        '_PCBNEW_PY=""',
        'for _c in "${KICAD_PYTHON:-}" ' +
        '"/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3" ' +
        'python3; do',
        '  [ -n "$_c" ] || continue',
        '  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c "import pcbnew" >/dev/null 2>&1; then _PCBNEW_PY="$_c"; break; fi',
        'done',
        'if [ -n "$_PCBNEW_PY" ]; then',
        '  "$_PCBNEW_PY" "%s" "$ROOT/%s" "$_FR"' % (ap.path, pcb),
        'else',
        # Degrade gracefully: skip routing (board just has no traces) rather than
        # failing on a platform without KiCad's Python (e.g. kicad-small on Linux).
        '  echo "autoroute: skipped — no pcbnew-capable python (need KiCad python; set KICAD_PYTHON)" >&2',
        'fi',
    ]
    return "\n".join(lines), [fr, ap]

def _picker_setup(ctx):
    # Run the local picker as a Bazel-managed sidecar (atopile 0.15.x requires a
    # components API for every pick). The interpreter is the nix `python3` the
    # rule depends on (`picker_python`, set by the macro only when `picker` is
    # on) — NOT the ambient `python3`, whose version varies (macOS ships 3.9).
    # The picker binds a free port and writes it to a file we read back; Bazel
    # tears down the action's process tree, so the sidecar can't leak. Returns
    # (start, stop, [input Files]). Footprints come from EasyEDA unless cached
    # under elec/src/parts.
    if not ctx.attr.picker or not ctx.file.picker_python:
        return "", "", []
    server = [f for f in ctx.files._picker if f.basename == "server.py"][0]
    lines = [
        '_PICKER_PY="$(readlink -f \'%s\' 2>/dev/null || echo \'%s\')"' % (ctx.file.picker_python.path, ctx.file.picker_python.path),
        '_ATO_PORTFILE="$(mktemp)"',
        '"$_PICKER_PY" "%s" 0 "$_ATO_PORTFILE" >/dev/null 2>&1 &' % server.path,
        '_ATO_PICKER_PID=$!',
        'for _i in $(seq 1 100); do [ -s "$_ATO_PORTFILE" ] && break; sleep 0.1; done',
        '[ -s "$_ATO_PORTFILE" ] || { echo "local picker did not come up" >&2; exit 1; }',
        'export ATO_SERVICES_COMPONENTS_URL="http://127.0.0.1:$(cat "$_ATO_PORTFILE")"',
    ]
    stop = 'kill "${_ATO_PICKER_PID:-}" 2>/dev/null || true'
    return "\n".join(lines), stop, ctx.files._picker + [ctx.file.picker_python]

def _run_ato(build, target, frozen):
    frozen_flag = "--frozen" if frozen else ""
    return '( cd "$ROOT" && "$ATO" build -b {build} -t {target} {frozen} )'.format(
        build = build,
        target = target,
        frozen = frozen_flag,
    )

# -- artifact rule: run one `ato build -t <target>` and collect one file -------

def _atopile_artifact_impl(ctx):
    info = _toolchain(ctx)
    out = ctx.outputs.out
    src = _OUTPUT_BASE.format(build = ctx.attr.build) + ctx.attr.src_suffix

    picker_start, picker_stop, picker_files = _picker_setup(ctx)

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        _root_setup(ctx),
        _ato_setup(info),
        _path_export(info),
        _fp_table_setup(ctx),
        picker_start,
        _run_ato(ctx.attr.build, ctx.attr.target, ctx.attr.frozen),
        picker_stop,
        'cp -f "$ROOT/{src}" "{out}"'.format(src = src, out = out.path),
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(transitive = [_project_inputs(ctx, info), depset(picker_files)]),
        command = cmd,
        mnemonic = "AtopileBuild",
        progress_message = "atopile %s -> %s" % (ctx.attr.target, out.short_path),
        use_default_shell_env = True,
        execution_requirements = {"local": "1", "no-sandbox": "1", "requires-network": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

_atopile_artifact = rule(
    implementation = _atopile_artifact_impl,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "build": attr.string(mandatory = True),
        "target": attr.string(mandatory = True, doc = "atopile build target, e.g. mfg-data."),
        "src_suffix": attr.string(mandatory = True, doc = "e.g. '.gerber.zip'."),
        "out": attr.output(mandatory = True),
        "picker": attr.bool(default = False, doc = "Run the local picker sidecar (0.15.x picking)."),
        "_picker": attr.label(default = "//tools/atopile-picker:picker"),
        "picker_python": attr.label(allow_single_file = True, cfg = "exec", doc = "nix python3 to run the picker (macro-set when picker on)."),
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- layout rule: THE pick step (non-hermetic) -> resolved .kicad_pcb ----------
#
# This is the ONE action that touches the network: it runs the local picker
# sidecar + `ato build` (part-picking + EasyEDA footprint download) + optional
# autoroute + framing, and emits the resolved, self-contained <build>.kicad_pcb
# (footprints embedded) plus the BOM. Every export below consumes that pcb with
# a hermetic `kicad-cli` — so the network is scoped to just this action.

def _atopile_layout_impl(ctx):
    info = _toolchain(ctx)
    pcb_out = ctx.actions.declare_file(ctx.label.name + ".kicad_pcb")
    bom_out = ctx.actions.declare_file(ctx.label.name + ".bom.csv")

    pcb = "elec/layout/{b}/{b}.kicad_pcb".format(b = ctx.attr.build)
    bom_src = _OUTPUT_BASE.format(build = ctx.attr.build) + ".bom.csv"
    frozen = "--frozen" if ctx.attr.frozen else ""

    inputs = [_project_inputs(ctx, info)]

    autoroute, ar_inputs = _autoroute_step(ctx, pcb)
    if ar_inputs:
        inputs.append(depset(ar_inputs))

    outline = ""
    if ctx.attr.outline_margin_mm > 0:
        inputs.append(depset([ctx.file._board_outline]))
        outline = 'python3 "{s}" "$ROOT/{pcb}" {m}'.format(
            s = ctx.file._board_outline.path,
            pcb = pcb,
            m = ctx.attr.outline_margin_mm,
        )

    picker_start, picker_stop, picker_files = _picker_setup(ctx)
    if picker_files:
        inputs.append(depset(picker_files))

    build_ato = '( cd "$ROOT" && "$ATO" build -b {build} {frozen} )'.format(build = ctx.attr.build, frozen = frozen)

    # Autorouting needs the pads' nets, but atopile's FIRST build only creates
    # the layout (pads on net 0) — a second build pushes the nets onto it.
    second_build = build_ato if ctx.attr.autoroute else ""

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        _root_setup(ctx),
        _ato_setup(info),
        _path_export(info),
        _fp_table_setup(ctx),
        picker_start,
        build_ato,
        second_build,
        picker_stop,
        autoroute,
        outline,
        'cp -f "$ROOT/{pcb}" "{o}"'.format(pcb = pcb, o = pcb_out.path),
        'if [ -f "$ROOT/{b}" ]; then cp -f "$ROOT/{b}" "{o}"; else : > "{o}"; fi'.format(b = bom_src, o = bom_out.path),
    ])

    ctx.actions.run_shell(
        outputs = [pcb_out, bom_out],
        inputs = depset(transitive = inputs),
        command = cmd,
        mnemonic = "AtopileLayout",
        progress_message = "atopile pick + layout -> %s" % pcb_out.short_path,
        use_default_shell_env = True,
        execution_requirements = {"local": "1", "no-sandbox": "1", "requires-network": "1"},
    )
    transitive = [dep[AtopileLibraryInfo].transitive_srcs for dep in ctx.attr.deps]
    return [
        DefaultInfo(files = depset([pcb_out])),
        AtopileLayoutInfo(pcb = pcb_out, bom = bom_out),
        AtopileProjectInfo(
            build_name = ctx.attr.build,
            ato_yaml = ctx.file.ato_yaml,
            transitive_srcs = depset(ctx.files.srcs, transitive = transitive),
        ),
    ]

_atopile_layout = rule(
    implementation = _atopile_layout_impl,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "build": attr.string(mandatory = True),
        "outline_margin_mm": attr.int(default = 0, doc = "Frame the board (see tools/board_outline.py) if > 0."),
        "_board_outline": attr.label(default = "//tools:board_outline.py", allow_single_file = True),
        "autoroute": attr.bool(default = False, doc = "Headless FreeRouting pass (see tools/autoroute.py)."),
        "freerouting": attr.label(allow_single_file = True, doc = "FreeRouting binary; macro-set when autoroute on."),
        "_autoroute": attr.label(default = "//tools:autoroute.py", allow_single_file = True),
        "picker": attr.bool(default = False, doc = "Run the local picker sidecar (0.15.x picking)."),
        "_picker": attr.label(default = "//tools/atopile-picker:picker"),
        "picker_python": attr.label(allow_single_file = True, cfg = "exec", doc = "nix python3 to run the picker (macro-set when picker on)."),
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- pdf rule: HERMETIC export of a resolved .kicad_pcb via kicad-cli ----------

def _atopile_pdf_impl(ctx):
    info = _toolchain(ctx)
    out = ctx.outputs.out
    pcb = ctx.attr.layout[AtopileLayoutInfo].pcb

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        '"{kc}" pcb export pdf "{pcb}" -o "{out}" --layers "{layers}"'.format(
            kc = _kicad_cmd(info),
            pcb = pcb.path,
            out = out.path,
            layers = ctx.attr.layers,
        ),
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset([pcb], transitive = [_tool_inputs(info)]),
        command = cmd,
        mnemonic = "AtopilePdf",
        progress_message = "atopile board PDF -> %s" % out.short_path,
        use_default_shell_env = True,
        # HERMETIC: only kicad-cli on the resolved pcb — no network, no picker.
        execution_requirements = {"local": "1", "no-sandbox": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

_atopile_pdf = rule(
    implementation = _atopile_pdf_impl,
    attrs = {
        "layout": attr.label(providers = [AtopileLayoutInfo], mandatory = True, doc = "The layout target whose .kicad_pcb to export."),
        "out": attr.output(mandatory = True),
        "layers": attr.string(
            default = "F.Cu,B.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts",
        ),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- gerber rule: HERMETIC Gerber + drill export via kicad-cli ------------------
#
# Manufacturing outputs straight off the resolved .kicad_pcb — kicad-cli only,
# no network/picker. Emits a directory (tree artifact) of Gerber layers + the
# Excellon drill files; a fab house consumes the directory (or you zip it).
# Directory output avoids depending on an ambient `zip`, keeping it hermetic.

def _atopile_gerber_impl(ctx):
    info = _toolchain(ctx)
    outdir = ctx.actions.declare_directory(ctx.label.name)
    pcb = ctx.attr.layout[AtopileLayoutInfo].pcb
    kc = _kicad_cmd(info)

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        'mkdir -p "{d}"'.format(d = outdir.path),
        '"{kc}" pcb export gerbers "{pcb}" -o "{d}/"'.format(kc = kc, pcb = pcb.path, d = outdir.path),
        '"{kc}" pcb export drill "{pcb}" -o "{d}/"'.format(kc = kc, pcb = pcb.path, d = outdir.path),
    ])

    ctx.actions.run_shell(
        outputs = [outdir],
        inputs = depset([pcb], transitive = [_tool_inputs(info)]),
        command = cmd,
        mnemonic = "AtopileGerber",
        progress_message = "atopile Gerbers -> %s" % outdir.short_path,
        use_default_shell_env = True,
        # HERMETIC: only kicad-cli on the resolved pcb — no network, no picker.
        execution_requirements = {"local": "1", "no-sandbox": "1"},
    )
    return [DefaultInfo(files = depset([outdir]))]

_atopile_gerber = rule(
    implementation = _atopile_gerber_impl,
    attrs = {
        "layout": attr.label(providers = [AtopileLayoutInfo], mandatory = True, doc = "The layout target whose .kicad_pcb to export."),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- base build rule: `ato build -b <build>` (design compiles) -----------------

def _atopile_build_impl(ctx):
    info = _toolchain(ctx)
    marker = ctx.actions.declare_file(ctx.label.name + ".buildinfo")
    frozen = "--frozen" if ctx.attr.frozen else ""

    picker_start, picker_stop, picker_files = _picker_setup(ctx)

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        _root_setup(ctx),
        _ato_setup(info),
        _path_export(info),
        _fp_table_setup(ctx),
        picker_start,
        '( cd "$ROOT" && "$ATO" build -b {build} {frozen} )'.format(
            build = ctx.attr.build,
            frozen = frozen,
        ),
        picker_stop,
        'echo "atopile build {build} OK" > "{out}"'.format(build = ctx.attr.build, out = marker.path),
    ])

    ctx.actions.run_shell(
        outputs = [marker],
        inputs = depset(transitive = [_project_inputs(ctx, info), depset(picker_files)]),
        command = cmd,
        mnemonic = "AtopileBuildAll",
        progress_message = "atopile build %s" % ctx.attr.build,
        use_default_shell_env = True,
        execution_requirements = {"local": "1", "no-sandbox": "1", "requires-network": "1"},
    )

    transitive = [dep[AtopileLibraryInfo].transitive_srcs for dep in ctx.attr.deps]
    return [
        DefaultInfo(files = depset([marker])),
        AtopileProjectInfo(
            build_name = ctx.attr.build,
            ato_yaml = ctx.file.ato_yaml,
            transitive_srcs = depset(ctx.files.srcs, transitive = transitive),
        ),
    ]

_atopile_build = rule(
    implementation = _atopile_build_impl,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "build": attr.string(mandatory = True),
        "picker": attr.bool(default = False, doc = "Run the local picker sidecar (0.15.x picking)."),
        "_picker": attr.label(default = "//tools/atopile-picker:picker"),
        "picker_python": attr.label(allow_single_file = True, cfg = "exec", doc = "nix python3 to run the picker (macro-set when picker on)."),
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- run rule: interactive `bazel run` targets (.view, .schematic) -------------

def _atopile_run_impl(ctx):
    info = _toolchain(ctx)
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    project_dir = ctx.file.ato_yaml.dirname
    layout_dir = "elec/layout/{b}".format(b = ctx.attr.build)

    # `bazel run` sets BUILD_WORKSPACE_DIRECTORY to the real source root; run
    # atopile there so it opens/serves the actual project (and its layout you can
    # edit), not a sandbox copy. Prefer the nix toolchain's `ato` from runfiles
    # so `bazel run …:foo.view` works WITHOUT `nix develop`; fall back to `ato`
    # on PATH (the host toolchain / dev shell). `ato build --open` finds KiCad
    # itself (nixpkgs kicad on Linux; the system KiCad.app on macOS).
    runfiles = ctx.runfiles(files = ctx.files.srcs + [ctx.file.ato_yaml])
    if info.ato:
        runfiles = runfiles.merge(ctx.runfiles(files = [info.ato], transitive_files = info.runfiles))
    if ctx.attr.picker and ctx.files._picker:
        runfiles = runfiles.merge(ctx.runfiles(files = ctx.files._picker))

    # atopile 0.15.x picks parts on EVERY build — including `ato build --open`
    # (the .view target). So a build-y run target needs the same local picker
    # sidecar the build actions use, else picking hits the stale/absent
    # components URL from ato.yaml. Start it here from runfiles (PATH python3;
    # server.py is 3.9-compatible), point atopile at it, and reap it on exit.
    # `serve core` (.schematic) doesn't pick, so it opts out (picker=False) and
    # keeps exec semantics (Ctrl-C stops the server).
    picker_block = ""
    run_line = 'exec "$ATO" @@ARGV@@'
    if ctx.attr.picker:
        picker_block = "\n".join([
            "_SRV=\"$(find -L \"$_rf\" -path '*/atopile-picker/server.py' 2>/dev/null | head -1)\"",
            "if [ -n \"$_SRV\" ] && command -v python3 >/dev/null 2>&1; then",
            "  _PF=\"$(mktemp)\"",
            "  python3 \"$_SRV\" 0 \"$_PF\" >/dev/null 2>&1 &",
            "  _PICKER_PID=$!",
            "  trap 'kill \"${_PICKER_PID:-}\" 2>/dev/null || true' EXIT",
            "  for _i in $(seq 1 100); do [ -s \"$_PF\" ] && break; sleep 0.1; done",
            "  if [ -s \"$_PF\" ]; then export ATO_SERVICES_COMPONENTS_URL=\"http://127.0.0.1:$(cat \"$_PF\")\"; else echo \"local picker did not come up\" >&2; fi",
            "fi",
        ])
        # Run in foreground (not exec) so the EXIT trap reaps the picker after.
        run_line = '"$ATO" @@ARGV@@'

    # Token-replace (not .format) so shell ${...}/[...] pass through literally.
    script = """#!/usr/bin/env bash
set -euo pipefail
# Locate `ato`: the nix toolchain binary in runfiles, else PATH (nix develop).
_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
_rf="${RUNFILES_DIR:-${_self}.runfiles}"
ATO=""
[ -d "$_rf" ] && ATO="$(find -L "$_rf" -path '*/bin/ato' 2>/dev/null | head -1)"
[ -n "$ATO" ] || ATO="ato"
if ! { command -v "$ATO" >/dev/null 2>&1 || [ -x "$ATO" ]; }; then
  echo "atopile 'ato' not found — run inside 'nix develop', or build with the nix toolchain." >&2
  exit 127
fi
cd "${BUILD_WORKSPACE_DIRECTORY:-.}/@@PROJECT_DIR@@"
# Seed the stock fp-lib-table (resolved next to `ato`) so explicit
# component.footprint ids resolve, same as the build rules do.
_fptbl="$(python3 -c 'import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$ATO" 2>/dev/null)/share/atopile/stock-fp-lib-table"
# chmod u+w: the stock table is read-only (nix store) but atopile 0.15.x
# rewrites the project fp-lib-table while picking (else [Errno 13]).
if [ -f "$_fptbl" ]; then mkdir -p "@@LAYOUT_DIR@@"; cp -f "$_fptbl" "@@LAYOUT_DIR@@/fp-lib-table"; chmod u+w "@@LAYOUT_DIR@@/fp-lib-table"; fi
# `ato serve core` (the .schematic target) reads its port from this env var.
export ATOPILE_CORE_SERVER_PORT="${ATOPILE_CORE_SERVER_PORT:-8080}"
@@PICKER@@
@@RUN@@
"""
    script = script.replace("@@PICKER@@", picker_block)
    script = script.replace("@@RUN@@", run_line)
    script = script.replace("@@PROJECT_DIR@@", project_dir)
    script = script.replace("@@LAYOUT_DIR@@", layout_dir)
    script = script.replace("@@ARGV@@", " ".join(ctx.attr.args_))
    ctx.actions.write(output = launcher, is_executable = True, content = script)
    return [DefaultInfo(executable = launcher, runfiles = runfiles)]

_atopile_run = rule(
    implementation = _atopile_run_impl,
    executable = True,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "build": attr.string(mandatory = True, doc = "build config, for the layout dir."),
        "args_": attr.string_list(mandatory = True, doc = "argv passed to `ato`."),
        "picker": attr.bool(default = False, doc = "Start the local picker sidecar before running `ato` (needed for build-y targets like .view; 0.15.x picks every build)."),
        "_picker": attr.label(default = "//tools/atopile-picker:picker"),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- library rule: reusable modules/components --------------------------------

def _atopile_library_impl(ctx):
    transitive = [dep[AtopileLibraryInfo].transitive_srcs for dep in ctx.attr.deps]
    manifests = [dep[AtopileLibraryInfo].manifests for dep in ctx.attr.deps]
    direct_manifests = [ctx.file.ato_yaml] if ctx.file.ato_yaml else []
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        AtopileLibraryInfo(
            transitive_srcs = depset(ctx.files.srcs, transitive = transitive),
            import_name = ctx.attr.import_name,
            manifests = depset(direct_manifests, transitive = manifests),
        ),
    ]

atopile_library = rule(
    implementation = _atopile_library_impl,
    doc = "A reusable set of atopile modules/components consumed via `deps`.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".ato", ".py"],
            doc = "The .ato (and optional .py) sources defining the modules.",
        ),
        "deps": attr.label_list(
            providers = [AtopileLibraryInfo],
            doc = "Other atopile_library targets this one builds on.",
        ),
        "ato_yaml": attr.label(
            allow_single_file = True,
            doc = "Optional ato.yaml declaring this as a publishable package.",
        ),
        "import_name": attr.string(
            doc = "Identifier used in downstream `from \"<name>\" import ...`.",
        ),
    },
)

# Re-exported so the public macro file can construct these rules.
atopile_artifact = _atopile_artifact
atopile_layout = _atopile_layout
atopile_pdf = _atopile_pdf
atopile_gerber = _atopile_gerber
atopile_build = _atopile_build
atopile_run = _atopile_run
