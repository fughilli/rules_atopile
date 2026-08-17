"""Rule implementations behind the `atopile_project` / `atopile_library` macros.

atopile builds are not naturally hermetic: part-picking calls the JLCPCB API and
dependency resolution hits the package registry. So the artifact rules run as
`local`, `requires-network` actions — Bazel orchestrates, caches by inputs, and
collects the declared outputs, while reproducibility comes from (a) a pinned
`ato` (the Nix derivation), (b) a committed KiCad layout, and (c) `--frozen`,
which forbids atopile from mutating that layout mid-build.
"""

load(":providers.bzl", "AtopileLibraryInfo", "AtopileProjectInfo", "AtopileToolchainInfo")

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

def _fp_lib_table_setup(ctx):
    # Explicit `component.footprint = "Lib:Name"` identifiers resolve ONLY against
    # the project's fp-lib-table (atopile does not consult KiCad's global table),
    # so seed it before building from the stock table the atopile derivation
    # ships at <atopile>/share/atopile/stock-fp-lib-table. We locate it relative
    # to the resolved `ato` binary (`$ATO`, set by _ato_setup) rather than as a
    # Bazel input, because rules_nixpkgs' generated BUILD only exposes bin/lib/
    # include — and these actions are `local`/`no-sandbox`, so the store path is
    # readable directly. Works for both toolchains (nix: $ATO is an absolute
    # store path; host: `command -v` resolves the devShell wrapper). The table
    # embeds /nix/store URIs and is gitignored. atopile's default layout path is
    # elec/layout/<build>/.
    layout_dir = "elec/layout/{build}".format(build = ctx.attr.build)
    return "\n".join([
        'mkdir -p "$ROOT/{ld}"'.format(ld = layout_dir),
        '_ato_real="$(readlink -f "$(command -v "$ATO")")"',
        '_fp_tbl="$(dirname "$(dirname "$_ato_real")")/share/atopile/stock-fp-lib-table"',
        'if [ -f "$_fp_tbl" ]; then cp -f "$_fp_tbl" "$ROOT/{ld}/fp-lib-table"; fi'.format(ld = layout_dir),
    ])

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

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        'ROOT="$(dirname "{ato_yaml}")"'.format(ato_yaml = ctx.file.ato_yaml.path),
        _ato_setup(info),
        _path_export(info),
        _fp_lib_table_setup(ctx),
        _run_ato(ctx.attr.build, ctx.attr.target, ctx.attr.frozen),
        'cp -f "$ROOT/{src}" "{out}"'.format(src = src, out = out.path),
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = _project_inputs(ctx, info),
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
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- pdf rule: export the board layout to PDF via kicad-cli --------------------

def _atopile_pdf_impl(ctx):
    info = _toolchain(ctx)
    out = ctx.outputs.out

    # Export the PDF from the canonical board layout atopile writes/refreshes at
    # elec/layout/<build>/<build>.kicad_pcb. (The mfg-data copies under build/
    # are timestamped, so their name isn't predictable.) A base `ato build`
    # produces/updates that layout; no need for the heavier mfg-data target.
    pcb = "elec/layout/{b}/{b}.kicad_pcb".format(b = ctx.attr.build)
    frozen = "--frozen" if ctx.attr.frozen else ""

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        'ROOT="$(dirname "{ato_yaml}")"'.format(ato_yaml = ctx.file.ato_yaml.path),
        _ato_setup(info),
        _path_export(info),
        _fp_lib_table_setup(ctx),
        '( cd "$ROOT" && "$ATO" build -b {build} {frozen} )'.format(build = ctx.attr.build, frozen = frozen),
        '"{kc}" pcb export pdf "$ROOT/{pcb}" -o "{out}" --layers "{layers}"'.format(
            kc = _kicad_cmd(info),
            pcb = pcb,
            out = out.path,
            layers = ctx.attr.layers,
        ),
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = _project_inputs(ctx, info),
        command = cmd,
        mnemonic = "AtopilePdf",
        progress_message = "atopile board PDF -> %s" % out.short_path,
        use_default_shell_env = True,
        execution_requirements = {"local": "1", "no-sandbox": "1", "requires-network": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

_atopile_pdf = rule(
    implementation = _atopile_pdf_impl,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "build": attr.string(mandatory = True),
        "out": attr.output(mandatory = True),
        "layers": attr.string(
            default = "F.Cu,B.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts",
        ),
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- base build rule: `ato build -b <build>` (design compiles) -----------------

def _atopile_build_impl(ctx):
    info = _toolchain(ctx)
    marker = ctx.actions.declare_file(ctx.label.name + ".buildinfo")
    frozen = "--frozen" if ctx.attr.frozen else ""

    cmd = "\n".join([
        "set -euo pipefail",
        _home_export(),
        'ROOT="$(dirname "{ato_yaml}")"'.format(ato_yaml = ctx.file.ato_yaml.path),
        _ato_setup(info),
        _path_export(info),
        _fp_lib_table_setup(ctx),
        '( cd "$ROOT" && "$ATO" build -b {build} {frozen} )'.format(
            build = ctx.attr.build,
            frozen = frozen,
        ),
        'echo "atopile build {build} OK" > "{out}"'.format(build = ctx.attr.build, out = marker.path),
    ])

    ctx.actions.run_shell(
        outputs = [marker],
        inputs = _project_inputs(ctx, info),
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
        "frozen": attr.bool(default = True),
    },
    toolchains = [TOOLCHAIN_TYPE],
)

# -- run rule: interactive `bazel run` targets (.view, .schematic) -------------

def _atopile_run_impl(ctx):
    info = _toolchain(ctx)
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    project_dir = ctx.file.ato_yaml.dirname

    # `bazel run` sets BUILD_WORKSPACE_DIRECTORY to the real source root; run
    # atopile there so it opens/serves the actual project, not a sandbox copy.
    # These targets use `ato`/`kicad-cli` from PATH (the Nix devShell), which is
    # the right model for interactive tools.
    ctx.actions.write(
        output = launcher,
        is_executable = True,
        content = """#!/usr/bin/env bash
set -euo pipefail
cd "${{BUILD_WORKSPACE_DIRECTORY:-.}}/{project_dir}"
exec {ato} {argv}
""".format(
            project_dir = project_dir,
            ato = info.ato_path,
            argv = " ".join(ctx.attr.args_),
        ),
    )
    return [DefaultInfo(
        executable = launcher,
        runfiles = ctx.runfiles(files = ctx.files.srcs + [ctx.file.ato_yaml]),
    )]

_atopile_run = rule(
    implementation = _atopile_run_impl,
    executable = True,
    attrs = {
        "ato_yaml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [AtopileLibraryInfo]),
        "args_": attr.string_list(mandatory = True, doc = "argv passed to `ato`."),
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
atopile_pdf = _atopile_pdf
atopile_build = _atopile_build
atopile_run = _atopile_run
