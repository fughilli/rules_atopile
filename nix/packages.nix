# Single source of truth for the atopile + kicad derivations, usable from both
# the flake (`flake.nix`) and rules_nixpkgs (`nix_pkg.file`, see MODULE.bazel).
#
# rules_nixpkgs invokes .nix files with plain `import <nixpkgs>`, so this file
# must work without flakes. It accepts an already-instantiated `pkgs`.
{ pkgs ? import <nixpkgs> { } }:
rec {
  # KiCad provides `kicad-cli`, which atopile calls for every export, plus the
  # standard footprint/symbol libraries designs reference. `kicad-small` is the
  # full CLI + libraries WITHOUT the multi-GB `kicad-packages3d` 3D models and
  # docs: PDF/gerber export is 2D-only, so the 3D models are dead weight (and
  # big enough to exhaust disk while building). Swap back to `pkgs.kicad` only
  # if a build needs 3D export/render.
  kicad = pkgs.kicad-small;

  # The stock footprint `.pretty` libraries. `kicad-small` drops the `libraries`
  # passthru, so source them from the full `pkgs.kicad` (same nixpkgs pin, so
  # same library version) and hand them to atopile for the stock fp-lib-table.
  kicad-footprints = pkgs.kicad.libraries.footprints;

  atopile = pkgs.callPackage ./atopile.nix {
    inherit kicad;
    kicadFootprints = kicad-footprints;
    # MUST pass python explicitly: `callPackage` would otherwise auto-fill the
    # `python` arg from `pkgs.python`, which in nixpkgs is an alias for Python
    # *2.7* (insecure, and unusable by uv) rather than the arg's `python313`
    # default. atopile 0.10.x wants 3.13.
    python = pkgs.python313;
    # Pinned resolved-venv hash. Reproducible since 2026-08-15 (the determinism
    # pass in atopile.nix strips sdist-build nondeterminism and removes the
    # self-referential shebangs that used to make any pin drift — see the
    # outputHash note there). To re-pin after a version bump, set this to
    # lib.fakeHash, run `nix build .#atopile`, and paste the reported "got:" hash.
    #
    # PLATFORM-SPECIFIC (aarch64-linux): the venv compiles extensions wherever
    # PyPI ships no wheel, so a repo also targeting e.g. aarch64-darwin must key
    # venvHash by pkgs.stdenv.hostPlatform.system.
    venvHash = "sha256-9y20YAaYHBC8ot8GGgYr7rSr+kIKwpOpX6aBv295Idw=";
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
