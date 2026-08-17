{
  description = "atopile toolchain (compiler + KiCad CLI) for Bazel/Nix PCB projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        inherit (pkgs) lib;
        packages = import ./nix/packages.nix { inherit pkgs; };
      in
      {
        # `kicad` is null on darwin (nixpkgs KiCad is broken there; atopile uses
        # the system KiCad.app), so only expose it as a package where it exists.
        packages = {
          inherit (packages) atopile atopile-latest;
          default = packages.atopile;
        } // lib.optionalAttrs (packages.kicad != null) {
          inherit (packages) kicad;
        };

        # `nix develop` gives you `ato` and `bazel` on PATH (plus `kicad-cli` on
        # Linux; on macOS atopile locates the system KiCad.app itself). This is
        # what the Bazel *host* toolchain resolves against and what
        # `bazel run …:foo.view` needs.
        devShells.default = pkgs.mkShell {
          packages = [
            packages.atopile
            pkgs.bazelisk
            pkgs.git
          ] ++ lib.optional (packages.kicad != null) packages.kicad;
          shellHook = ''
            echo "atopile $(ato --version 2>/dev/null || echo '?') + $(kicad-cli version 2>/dev/null || echo 'system kicad-cli') ready"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
