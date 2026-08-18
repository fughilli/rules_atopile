# Single source of truth for the atopile + kicad derivations, usable from both
# the flake (`flake.nix`) and rules_nixpkgs (`nix_pkg.file`, see MODULE.bazel).
#
# rules_nixpkgs invokes .nix files with plain `import <nixpkgs>`, so this file
# must work without flakes. It accepts an already-instantiated `pkgs`.
{ pkgs ? import <nixpkgs> { } }:
let
  inherit (pkgs) lib;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # KiCad provides `kicad-cli`, which atopile calls for every export. On Linux
  # that's `kicad-small` (full CLI + libraries WITHOUT the multi-GB
  # `kicad-packages3d` 3D models — PDF/gerber is 2D, and they're big enough to
  # exhaust disk). On aarch64-darwin nixpkgs marks the KiCad *application* broken
  # (a long-standing macOS build issue), so we can't build it — pass `null` and
  # let atopile's `find_kicad_cli` use the system KiCad.app (/Applications/KiCad)
  # instead. The footprint libraries (below) are a separate, non-broken package
  # used on both platforms.
  kicadApp = if isDarwin then null else pkgs.kicad-small;

  # atopile version. 0.15.x is a compiler rewrite vs 0.10.x — needs Python 3.14
  # (Requires-Python >=3.14,<3.15) and picks parts via lcsc_id/mpn/package (no
  # explicit-footprint `.ato` attribute anymore). Its deps resolve cleanly, so
  # no extraPipPackages (0.10.x needed `mcp<2`).
  version = "0.15.8";

  # The venv compiles extensions wherever PyPI ships no wheel, so the resolved
  # tree — and thus `venvHash` — is PER-PLATFORM (and per-version). Keyed by
  # system here. Re-pin after a version bump: set the entry to lib.fakeHash, run
  # `nix build .#atopile`, paste the reported "got:" hash. The venv FOD is
  # reproducible (determinism pass in atopile.nix), so the pin holds.
  venvHashBySystem = {
    "aarch64-linux" = "sha256-AAXyNGp2PaQSfcQmwOakRUpkm6UF/irnUm7iqXjMaxo=";
    "aarch64-darwin" = lib.fakeHash; # re-pin on the mac
  };
  venvHash = venvHashBySystem.${pkgs.stdenv.hostPlatform.system} or lib.fakeHash;
in
rec {
  # Exposed as `kicad` for the flake/devShell; null on darwin (system KiCad).
  kicad = kicadApp;

  # FreeRouting 2.2.4 (headless), for the autoroute flow — the nixpkgs pin's
  # 2.1.0 blocks on a GUI email dialog and routes nothing. See freerouting.nix.
  freerouting = pkgs.callPackage ./freerouting.nix { };

  # The stock footprint `.pretty` libraries — a SEPARATE data package
  # (`kicad.libraries.footprints`), not the broken KiCad app, so it builds on
  # both Linux and darwin. Handed to atopile for the stock fp-lib-table.
  kicad-footprints = pkgs.kicad.libraries.footprints;

  atopile = pkgs.callPackage ./atopile.nix {
    kicad = kicadApp;
    kicadFootprints = kicad-footprints;
    inherit version;
    # MUST pass python explicitly: `callPackage` would otherwise auto-fill the
    # `python` arg from `pkgs.python`, which in nixpkgs is an alias for Python
    # *2.7* (insecure, and unusable by uv). 0.15.x wants 3.14.
    python = pkgs.python314;
    extraPipPackages = [ ];
    inherit venvHash;
  };
}
