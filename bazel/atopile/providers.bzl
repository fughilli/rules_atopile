"""Providers shared across the atopile Bazel rules."""

AtopileToolchainInfo = provider(
    doc = "Locates the `ato` compiler and `kicad-cli` for build/export actions.",
    fields = {
        "ato": "File or None: the `ato` executable (nix toolchain); None => use ato_path.",
        "kicad_cli": "File or None: the `kicad-cli` executable; None => use kicad_cli_path.",
        "ato_path": "string: command used when `ato` is None (host toolchain, from PATH).",
        "kicad_cli_path": "string: command used when `kicad_cli` is None.",
        "runfiles": "depset[File]: closure files that must be present as action inputs.",
    },
)

AtopileLibraryInfo = provider(
    doc = "A reusable set of atopile modules/components (wraps the ato `module` concept).",
    fields = {
        "transitive_srcs": "depset[File]: this library's sources plus those of its deps.",
        "import_name": "string: identifier used in path imports, or '' if unset.",
        "manifests": "depset[File]: ato.yaml manifests of this library and its deps.",
    },
)

AtopileProjectInfo = provider(
    doc = "Metadata describing an atopile project target.",
    fields = {
        "build_name": "string: the selected build config from ato.yaml.",
        "ato_yaml": "File: the project's ato.yaml manifest.",
        "transitive_srcs": "depset[File]: project sources plus transitive library sources.",
    },
)
