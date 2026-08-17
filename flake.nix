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
        packages = import ./nix/packages.nix { inherit pkgs; };
      in
      {
        packages = {
          inherit (packages) atopile atopile-latest kicad;
          default = packages.atopile;
        };

        # `nix develop` gives you `ato`, `kicad-cli` and `bazel` on PATH — this
        # is what the Bazel *host* toolchain (//bazel/atopile:host_toolchain)
        # resolves against, and what `bazel run …:foo.view` needs.
        devShells.default = pkgs.mkShell {
          packages = [
            packages.atopile
            packages.kicad
            pkgs.bazelisk
            pkgs.git
          ];
          shellHook = ''
            echo "atopile $(ato --version 2>/dev/null || echo '?') + $(kicad-cli version 2>/dev/null || echo kicad-cli) ready"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
