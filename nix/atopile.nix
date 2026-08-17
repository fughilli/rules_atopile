# atopile packaged as a Nix derivation.
#
# atopile is published to PyPI but its dependency closure (faebryk,
# atopile-kicad-python, shapely, numpy, fastapi, ...) is large and not carried
# in nixpkgs. Rather than hand-maintain a `buildPythonPackage` with dozens of
# overrides, we resolve the *entire* closure with `uv` inside a fixed-output
# derivation (FOD). The FOD's `outputHash` pins the fully-resolved tree, so the
# result is reproducible: same atopile version + same uv resolution => same hash.
#
# At runtime atopile shells out to `kicad-cli` for every export (gerber, glb,
# step, pdf, svg, dxf). We therefore wrap `ato` so KiCad is always on PATH.
#
# To (re)pin after bumping `version`: set `venvHash = lib.fakeHash;`, run
# `nix build .#atopile`, and copy the "got:" hash Nix reports back into this file.
{
  lib,
  stdenv,
  stdenvNoCC,
  uv,
  python313,
  cacert,
  git,
  binutils,
  patchelf,
  kicad,
  # KiCad's stock footprint libraries (the `.pretty` dirs). `kicad-small` ships
  # only the CLI + binaries, so the libraries are a separate package. atopile
  # resolves an explicit `component.footprint = "Lib:Name"` against a project
  # `fp-lib-table` whose entries point at these `.pretty` dirs — so we bake a
  # stock table listing them all (see installPhase) that the build rule drops
  # into a project's layout dir. Defaults to the libraries of the passed `kicad`.
  kicadFootprints ? kicad.libraries.footprints,
  makeWrapper,
  # Pin the atopile release here. Keep in sync with rules/atopile-bazel-nix.md
  # and the `requires-atopile` field of downstream ato.yaml projects.
  version ? "0.10.23",
  # The interpreter to resolve the venv against. Defaults to python313 (what
  # atopile 0.10.x wants); atopile 0.15.x requires >=3.14, so pass python314.
  # Everything below keys the minor version off `python.pythonVersion`.
  python ? python313,
  # Extra pip specifiers layered on top of `atopile==<version>`. Used to steer
  # resolution around known-bad transitive picks — e.g. atopile 0.10.23 eagerly
  # imports `mcp.server.fastmcp`, which mcp 2.0 moved, so it needs `mcp<2`.
  extraPipPackages ? [ "mcp<2" ],
  # Hash of the resolved uv venv. `lib.fakeHash` forces a rebuild that prints
  # the real hash; replace it and commit. Per-version AND per-interpreter, so
  # bumping `version`/`python` requires re-pinning.
  venvHash ? lib.fakeHash,
}:
let
  pyVer = python.pythonVersion; # e.g. "3.13" or "3.14"

  # Fixed-output derivation: the only network access in the whole build.
  # Produces a self-contained, relocatable venv with `ato` on its bin/.
  #
  # stdenv (not stdenvNoCC): parts of the closure ship no wheel for every
  # platform — `zstd` has none for aarch64-linux — so uv falls back to building
  # the sdist and needs a working C toolchain. stdenvNoCC fails these with
  # "No such file or directory: 'gcc'".
  venv = stdenv.mkDerivation {
    pname = "atopile-venv";
    inherit version;

    dontUnpack = true;

    # Do not let nix's fixupPhase touch the venv. manylinux wheels ship their
    # native deps in a sibling `<pkg>.libs/` dir and reach them via an
    # `$ORIGIN/../<pkg>.libs` RPATH written by auditwheel. The default fixup runs
    # `patchelf --shrink-rpath` (plus strip), which drops that entry and leaves
    # the extension unable to find its own bundled library:
    #   ImportError: libgeos-9c5cb28e.so.3.13.1: cannot open shared object file
    # The venv is meant to be used exactly as uv produced it, so skip fixup.
    dontFixup = true;

    # git is load-bearing, not incidental: atopile's own build-system.requires
    # pins `scikit-build-core` to a git URL
    # (github:atopile/scikit-build-core@feature/allow_editable), so uv shells out
    # to `git` while resolving the build backend. Without it the FOD dies with
    # "Git executable not found" before any wheel is downloaded.
    # binutils/patchelf supply `objcopy`/`patchelf` for the determinism pass.
    nativeBuildInputs = [ uv python cacert git binutils patchelf ];

    # FOD plumbing: content-addressed, network allowed.
    #
    # Reproducible as of 2026-08-15 (was "KNOWN BROKEN"). The hash used to drift
    # every build for two independent reasons, both handled in the determinism
    # pass in postBuild below:
    #   1. sdist-built C extensions (only `zstd` on aarch64-linux; PyPI ships no
    #      wheel) baked uv's *random* sdist build path
    #      (/tmp/.tmp*/sdists-v*/.../<rand>/src) into DWARF debug info, and the
    #      GNU build-id hashed that. -> strip both from every .so.
    #   2. uv writes self-referential `#!$out/bin/python` shebangs into every
    #      console script. nix does NOT scrub self-references for FODs, so any
    #      pinned hash changes $out, which changes the content, which changes the
    #      hash: an unpinnable fixed-point trap. -> rewrite those shebangs out
    #      (ato is invoked as `${venv}/bin/python ${venv}/bin/ato` by the outer
    #      wrapper, so they are cosmetic), then assert $out appears nowhere.
    # With both applied, back-to-back builds are byte-identical and venvHash pins
    # cleanly (per-version and per-platform — see packages.nix).
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = venvHash;

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      # Never let uv fetch its own Python; use the pinned interpreter.
      export UV_PYTHON_DOWNLOADS=never
      export UV_PYTHON="${python}/bin/python${pyVer}"
      # copy (not hardlink/symlink) so the venv is self-contained under $out.
      export UV_LINK_MODE=copy

      # `extraPipPackages` steers resolution around known-bad transitive picks
      # (see the arg doc — e.g. atopile 0.10.23 needs `mcp<2` for its eager
      # `mcp.server.fastmcp` import). Empty for versions that resolve cleanly.
      uv venv --python "$UV_PYTHON" "$out"
      VIRTUAL_ENV="$out" uv pip install \
        --python "$out/bin/python" \
        --no-cache \
        "atopile==${version}" ${lib.escapeShellArgs extraPipPackages}

      # Drop uv's absolute-path activation scripts; the wrapper below is the
      # supported entrypoint and $out is stable (== final store path).
      rm -f "$out"/bin/activate*

      # --- Determinism + FOD-reference pass (see the outputHash comment) -------
      # An FOD must be self-contained: nix forbids its output from referencing
      # other store paths. A uv venv is not self-contained by default (it links
      # sdist-built extensions against nixpkgs glibc/gcc-lib and symlinks the
      # base interpreter), so we scrub every store reference here and let the
      # outer wrapper re-supply what's needed at runtime (LD_LIBRARY_PATH for
      # gcc-lib; the base interpreter + PYTHONPATH instead of bin/python).
      #
      # For every native extension: (a) strip debug info + build-id (they embed
      # uv's random sdist build path), and (b) drop every absolute /nix/store
      # RUNPATH entry (glibc, gcc-lib, and nix's auto-added self-referential
      # $out/lib). $ORIGIN-relative entries are kept, so manylinux wheels that
      # reach bundled libs via $ORIGIN are byte-untouched (unlike the default
      # fixup's `patchelf --shrink-rpath`, hence dontFixup). NAR ignores mtimes,
      # so content is all that matters for the hash.
      find "$out" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 \
        | while IFS= read -r -d "" so; do
            objcopy --remove-section .note.gnu.build-id --strip-debug "$so" 2>/dev/null || true
            rp="$(patchelf --print-rpath "$so" 2>/dev/null || true)"
            if [ -n "$rp" ]; then
              # grep exits 1 when every entry is filtered out; guard so set -e /
              # pipefail don't abort the build in that (expected) case.
              new="$( { printf '%s' "$rp" | tr ':' '\n' | grep -v '^/nix/store/' | paste -sd: - ; } || true )"
              [ "$new" = "$rp" ] || patchelf --set-rpath "$new" "$so" 2>/dev/null || true
            fi
          done

      # The base interpreter is reached via the outer wrapper (base python +
      # PYTHONPATH), so drop the venv's store-referencing interpreter symlinks
      # and pyvenv.cfg (home = <python>/bin). Their removal is what lets the FOD
      # be reference-free; site-packages (the part we actually want) stays.
      rm -f "$out/bin/python" "$out/bin/python3" "$out/bin/python${pyVer}" "$out/pyvenv.cfg"

      # Neutralize self-referential `#!$out/bin/python` shebangs on the remaining
      # console scripts. `ato` is run via the outer wrapper (base python +
      # PYTHONPATH on the `ato` entry script), so these shebangs are never
      # executed as-is; rewrite them to a store-path-independent form.
      for s in "$out"/bin/*; do
        [ -f "$s" ] || continue
        IFS= read -r first < "$s" || continue
        case "$first" in
          "#!$out/bin/python"*) sed -i '1s|.*|#!/usr/bin/env python3|' "$s" ;;
        esac
      done

      # Assert the venv no longer references its own output path anywhere, so the
      # FOD hash cannot depend on $out (which is what makes it pinnable). Both a
      # file whose *contents* embed $out and a *symlink whose target* embeds $out
      # count (NAR hashes symlink targets), so check each. Failing loudly here
      # beats shipping a venv that silently drifts.
      selfrefs="$( { find "$out" -type f -exec grep -lF "$out" {} + ; \
                     find "$out" -type l -lname "*$out*" ; } 2>/dev/null || true )"
      if [ -n "$selfrefs" ]; then
        echo "atopile venv: self-reference to $out remains in:" >&2
        printf '%s\n' "$selfrefs" >&2
        exit 1
      fi

      # --- Offline patch: short-circuit the empty part-picking query ----------
      # atopile's picker always calls ApiClient.fetch_parts_multiple(), even when
      # the design has ZERO parts to pick (e.g. everything uses explicit local
      # footprints). With an empty list it still POSTs `{"queries": []}` to the
      # components API, so a fully-local build dies on a DNS/connection error
      # with no network. Guard the method to return `[]` when there's nothing to
      # ask about — no query, no network. Assert the anchor still exists so a
      # version bump can't silently drop the patch (re-pin venvHash on bump).
      python3 - "$out"/lib/python*/site-packages/faebryk/libs/picker/api/api.py <<'PY'
      import sys
      p = sys.argv[1]
      src = open(p, encoding="utf-8").read()
      anchor = '        # TODO: batch queries\n'
      guard = '        if not params:\n            return []\n'
      assert anchor in src, f"empty-query patch anchor not found in {p}"
      if guard not in src:
          src = src.replace(anchor, guard + anchor, 1)
          open(p, "w", encoding="utf-8").write(src)
      PY

      # (3) pip RECORD files pin each installed file's sha256; the stripped .so
      # and rewritten shebangs no longer match, so regenerate every RECORD entry
      # against the normalized tree (else RECORD re-imports the nondeterminism).
      python3 - "$out"/lib/*/site-packages <<'PY'
      import base64, hashlib, os, sys
      def digest(p):
          h = hashlib.sha256(open(p, "rb").read()).digest()
          return "sha256=" + base64.urlsafe_b64encode(h).decode().rstrip("=")
      for site in sys.argv[1:]:
          for dist in os.listdir(site):
              rec = os.path.join(site, dist, "RECORD")
              if not (dist.endswith(".dist-info") and os.path.isfile(rec)):
                  continue
              out = []
              for line in open(rec, encoding="utf-8").read().splitlines():
                  path, _, rest = line.partition(",")
                  hash_field, _, _size = rest.partition(",")
                  full = os.path.normpath(os.path.join(site, path))
                  if hash_field.startswith("sha256=") and os.path.isfile(full):
                      out.append(f"{path},{digest(full)},{os.path.getsize(full)}")
                  else:
                      out.append(line)
              open(rec, "w", encoding="utf-8").write("\n".join(out) + "\n")
      PY
      runHook postBuild
    '';

    installPhase = "true";
  };
in
stdenvNoCC.mkDerivation {
  pname = "atopile";
  inherit version;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  # Surface the resolved venv and the KiCad used for exports for debugging /
  # downstream consumers (e.g. `nix build .#atopile.venv`).
  passthru = { inherit venv kicad python; };

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/atopile"

    # Stock KiCad footprint library table: one entry per `.pretty` dir in
    # kicad-footprints, with an absolute /nix/store URI. atopile's manual
    # footprint path (F.has_local_kicad_footprint) resolves a `Lib:Footprint`
    # identifier ONLY against the project's fp-lib-table — it does not consult
    # KiCad's global table — so the build rule copies this file into a project's
    # `elec/layout/<build>/fp-lib-table`. The URIs are absolute, so the atomic
    # footprints get read and embedded into the .kicad_pcb at build time.
    fp_dir="${kicadFootprints}/share/kicad/footprints"
    {
      echo "(fp_lib_table (version 7)"
      for pretty in "$fp_dir"/*.pretty; do
        name="$(basename "$pretty" .pretty)"
        echo "  (lib (name \"$name\")(type \"KiCad\")(uri \"$pretty\")(options \"\")(descr \"stock KiCad footprints\"))"
      done
      echo ")"
    } > "$out/share/atopile/stock-fp-lib-table"
    # The venv is a reference-free FOD, so it no longer carries an interpreter
    # (bin/python was removed to keep it self-contained). Run the base python on
    # the `ato` entry script with the venv's site-packages on PYTHONPATH — this
    # replaces venv activation and reaches atopile's entry point. `ato`'s own
    # shebang was rewritten to a non-self-ref form, so it must not be relied on.
    #
    # LD_LIBRARY_PATH carries gcc's runtime libs, which the venv's extensions
    # need now that their /nix/store RUNPATHs were scrubbed for FOD-reference
    # freedom: pynng's `_nng` needs libatomic.so.1 and faebryk_core_cpp needs
    # libstdc++ — both live in gcc's lib output — else `ato` dies with e.g.
    #   ImportError: libatomic.so.1: cannot open shared object file
    makeWrapper "${python}/bin/python${pyVer}" "$out/bin/ato" \
      --add-flags "${venv}/bin/ato" \
      --prefix PYTHONPATH : "${venv}/lib/python${pyVer}/site-packages" \
      --prefix PATH : "${lib.makeBinPath [ kicad ]}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" \
      --set-default ATO_NON_INTERACTIVE 1 \
      --set-default OPENSSL_armcap 0 \
      --set-default ATO_STOCK_FP_LIB_TABLE "$out/share/atopile/stock-fp-lib-table"
    # OPENSSL_armcap=0 disables OpenSSL's ARMv8 crypto-extension probe, whose
    # capability check SIGILLs (illegal instruction, exit 132) inside the
    # bundled `cryptography` Rust wheel on this aarch64 host (Apple-virt). With
    # it, ato runs; on x86 / real ARM it's a harmless no-op. --set-default keeps
    # a caller override possible. Baked into the wrapper so both `nix develop`
    # and the hermetic Bazel action get it without remembering an --action_env.
    runHook postInstall
  '';

  meta = with lib; {
    description = "Design circuit boards with code (packaged with a pinned KiCad CLI)";
    homepage = "https://atopile.io";
    license = licenses.mit;
    mainProgram = "ato";
    platforms = platforms.unix;
  };
}
