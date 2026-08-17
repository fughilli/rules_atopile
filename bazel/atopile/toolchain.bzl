"""The atopile toolchain: resolves `ato` and `kicad-cli` for the build rules.

Two flavours plug into the same `//bazel/atopile:toolchain_type`:

  * host  — `ato`/`kicad-cli` come from PATH (the Nix devShell or a system
            install). Zero Bazel<->Nix wiring; good for `bazel run …:foo.view`.
  * nix   — `ato`/`kicad-cli` are concrete files from rules_nixpkgs repos, so
            build/export actions are hermetic (see MODULE.bazel).
"""

load(":providers.bzl", "AtopileToolchainInfo")

def _atopile_toolchain_impl(ctx):
    ato = ctx.executable.ato
    kicad_cli = ctx.executable.kicad_cli
    runfiles = depset(
        direct = ctx.files.ato + ctx.files.kicad_cli + ctx.files.data,
    )
    return [platform_common.ToolchainInfo(
        atopileinfo = AtopileToolchainInfo(
            ato = ato,
            kicad_cli = kicad_cli,
            ato_path = ctx.attr.ato_path,
            kicad_cli_path = ctx.attr.kicad_cli_path,
            runfiles = runfiles,
        ),
    )]

atopile_toolchain = rule(
    implementation = _atopile_toolchain_impl,
    doc = "Declares an atopile toolchain (host or nix). Wrap in a `toolchain()`.",
    attrs = {
        "ato": attr.label(
            doc = "The `ato` executable. Leave unset for a host toolchain (uses ato_path).",
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "kicad_cli": attr.label(
            doc = "The `kicad-cli` executable. Leave unset for a host toolchain.",
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "ato_path": attr.string(
            doc = "Command used to invoke atopile when `ato` is unset.",
            default = "ato",
        ),
        "kicad_cli_path": attr.string(
            doc = "Command used to invoke KiCad when `kicad_cli` is unset.",
            default = "kicad-cli",
        ),
        "data": attr.label_list(
            doc = "Extra closure files (e.g. the whole nix store path) needed at action time.",
            allow_files = True,
        ),
    },
)
