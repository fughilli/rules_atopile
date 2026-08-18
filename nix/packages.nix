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

  # The venv compiles extensions wherever PyPI ships no wheel, so the resolved
  # tree — and thus `venvHash` — is PER-PLATFORM. Keyed by system here.
  venvHashBySystem = {
    "aarch64-linux" = "sha256-9y20YAaYHBC8ot8GGgYr7rSr+kIKwpOpX6aBv295Idw=";
    "aarch64-darwin" = "sha256-pEBefL1wFmBKdqf9wxmza8CBXF1Zand1Sf7Ix4bXMio=";
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
    # MUST pass python explicitly: `callPackage` would otherwise auto-fill the
    # `python` arg from `pkgs.python`, which in nixpkgs is an alias for Python
    # *2.7* (insecure, and unusable by uv) rather than the arg's `python313`
    # default. atopile 0.10.x wants 3.13.
    python = pkgs.python313;
    # Pinned resolved-venv hash (per-platform; see venvHashBySystem above). To
    # re-pin after a version bump, set the relevant entry to lib.fakeHash, run
    # `nix build .#atopile`, and paste the reported "got:" hash. The venv FOD is
    # reproducible (determinism pass in atopile.nix), so the pin holds.
    inherit venvHash;
  };

  # Latest atopile (0.15.x). Requires Python >=3.14 (python314 is in the pinned
  # nixpkgs), and defaults its component-picking API to the live but auth-gated
  # https://legacy.atopileapi.com. Its deps resolve cleanly, so no extraPipPackages.
  atopile-latest = pkgs.callPackage ./atopile.nix {
    inherit kicad;
    kicadFootprints = kicad-footprints;
    python = pkgs.python314;
    version = "0.15.8";
    extraPipPackages = [ ];
    venvHash = "sha256-pzDPd1zETPGv5cxgRmzZ9DvIaUxdvGiAEyI8quwxjhk=";
  };
}
