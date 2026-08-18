# FreeRouting pinned to 2.2.4 for the autoroute flow (see tools/autoroute.py).
#
# Why not nixpkgs' freerouting? The pin ships 2.1.0, which (a) pops a GUI email
# dialog even with `-gui.enabled false`, blocking headless runs, and (b) scores
# NaN / routes nothing. 2.2.x fixes both but its jar targets **Java 25**, which
# this pinned nixpkgs lacks (max jdk24) — and every 1.x that runs on an older
# JRE needs a display (HeadlessException). So we fetch the 2.2.4 release jar plus
# a pinned Temurin **JRE 25** and wrap them, forcing headless AWT.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  zlib,
}:
let
  version = "2.2.4";
  system = stdenv.hostPlatform.system;

  jar = fetchurl {
    url = "https://github.com/freerouting/freerouting/releases/download/v${version}/freerouting-${version}.jar";
    hash = "sha256-9e03QYKQDMx45HNRi7ufa4afSgcVlJX2Y6dvUrsQUjs=";
  };

  # Temurin JRE 25 (Adoptium), per-platform.
  jres = {
    "aarch64-linux" = {
      url = "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4%2B7/OpenJDK25U-jre_aarch64_linux_hotspot_25.0.4_7.tar.gz";
      sha256 = "1f2644427000316bc431df3389504551ed7464fe8486bf6b4f1130af9ffc8f55";
    };
    "aarch64-darwin" = {
      url = "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4%2B7/OpenJDK25U-jre_aarch64_mac_hotspot_25.0.4_7.tar.gz";
      sha256 = "bc5c721d4475b328e50cc0fbbe3319773db374716836e7caa8fb4398c1f90eba";
    };
  };
  jreInfo = jres.${system} or (throw "freerouting.nix: no pinned Temurin JRE 25 for ${system}");
  jreSrc = fetchurl { inherit (jreInfo) url sha256; };
in
stdenvNoCC.mkDerivation {
  pname = "freerouting";
  inherit version;
  dontUnpack = true;

  # Linux: the Temurin binaries are foreign ELFs; patch their interpreter/RUNPATH
  # (headless, so GUI libs like freetype are never dlopen'd — ignore if missing).
  nativeBuildInputs = [ makeWrapper ] ++ lib.optionals stdenv.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.isLinux [ stdenv.cc.cc.lib zlib ];
  autoPatchelfIgnoreMissingDeps = stdenv.isLinux;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/jre" "$out/share/freerouting"
    tar -xzf ${jreSrc} -C "$out/jre" --strip-components=1
    cp ${jar} "$out/share/freerouting/freerouting.jar"
    # macOS lays the JRE out under Contents/Home; Linux directly under bin/.
    _java="$out/jre/bin/java"
    [ -x "$_java" ] || _java="$out/jre/Contents/Home/bin/java"
    makeWrapper "$_java" "$out/bin/freerouting" \
      --add-flags "-Djava.awt.headless=true -jar $out/share/freerouting/freerouting.jar"
    runHook postInstall
  '';

  meta = {
    description = "FreeRouting PCB autorouter (headless; pinned 2.2.4 jar + Temurin JRE 25)";
    homepage = "https://github.com/freerouting/freerouting";
    license = lib.licenses.gpl3Only;
    mainProgram = "freerouting";
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
  };
}
