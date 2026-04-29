# Browser GPU/compositing wrapper — produces a SEPARATE package.
# Source of truth: ./browsers-gpu.json
# Tester:          ./test-browsers-gpu.sh
#
# Imported as a function: `import ./browsers-gpu.nix { inherit pkgs lib; }`
# returns `{ mkGpuVariant }`. Use:
#
#   home.packages = [ (mkGpuVariant "brave" pkgs.unstable.brave) ];
#
# This builds `<browser>-gpu` as a NEW package alongside the original — not
# an overlay. Both end up in the app menu / on $PATH:
#   brave        → original, untouched (Wayland default, software compositing)
#   brave-gpu    → wrapped (--ozone-platform=x11, hardware compositing)
#
# Why a separate package instead of an overlay:
#   - User wants to keep the unmodified brave for fallback / comparison.
#   - Avoids breaking downstream consumers (electron/etc. depend on
#     unmodified pkgs.<x>.override).
#   - Two .desktop entries appear in KDE app menu / KRunner: "Brave Web
#     Browser" (original) and "Brave GPU" (wrapped).

{ pkgs, lib }:
let
  cfg = builtins.fromJSON (builtins.readFile ./browsers-gpu.json);
in
{
  mkGpuVariant = browserKey: pkg:
    let
      entry = cfg.browsers.${browserKey} or
        (throw "browsers-gpu.json has no entry for '${browserKey}'");
      newBin = "${browserKey}-gpu";
      flagsStr = lib.concatStringsSep " " entry.flags;

      # Hand-rolled wrapper script — NOT makeWrapper. Why: makeWrapper
      # single-quotes its --add-flags args, which would prevent shell
      # expansion of $HOME inside --user-data-dir at launch time. Brave
      # itself doesn't expand env vars in CLI args, so $HOME must be
      # resolved by the wrapper's shell BEFORE exec'ing brave.
      wrapperScript = pkgs.writeShellScript "${newBin}-launcher" ''
        exec "${pkg}/bin/${browserKey}" ${flagsStr} --user-data-dir="$HOME/${entry.userDataDir}" "$@"
      '';
    in
    pkgs.symlinkJoin {
      name = "${browserKey}-gpu";
      paths = [ pkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        # ─── 1. Binary: replace bin/${browserKey} with NEW bin/${newBin} ──
        # symlinkJoin gave us $out/bin/${browserKey} as a symlink to the
        # original. Remove it so we don't shadow the original brave's bin
        # (both packages will be installed; only $out/bin/${newBin} should
        # be unique to this variant).
        if [ -e $out/bin/${browserKey} ] || [ -L $out/bin/${browserKey} ]; then
          rm $out/bin/${browserKey}
        fi
        install -m 755 ${wrapperScript} $out/bin/${newBin}

        # ─── 2. .desktop: copy + rename + patch ──────────────────────────
        # Each .desktop in the original gets a sibling `<name>-gpu.desktop`
        # that points at the wrapped binary and is labelled "<Name> GPU"
        # in the app menu. Original .desktop symlinks are removed so they
        # don't shadow the unwrapped pkg's own (which keeps its identity).
        if [ -d $out/share/applications ]; then
          for desktop in $out/share/applications/*.desktop; do
            [ -L "$desktop" ] || continue
            target=$(readlink -f "$desktop")
            base=$(basename "$desktop" .desktop)
            newDesktop="$out/share/applications/''${base}-gpu.desktop"

            cp "$target" "$newDesktop"
            chmod +w "$newDesktop"

            # 2a. Rewrite every absolute Exec= path → wrapped binary
            substituteInPlace "$newDesktop" \
              --replace '${pkg}/bin/${browserKey}' "$out/bin/${newBin}"

            # 2b. Append " GPU" to every Name= and Name[locale]= line so
            #     KDE / GNOME app menu shows it as a distinct entry.
            sed -i 's/^\(Name\(\[[^]]*\]\)\?=\)\(.*\)$/\1\3 GPU/' "$newDesktop"

            # 2c. Drop the original symlinked .desktop — we don't want
            #     this variant package shadowing the original .desktop.
            rm "$desktop"
          done
        fi
      '';
      meta = (pkg.meta or {}) // {
        description = (pkg.meta.description or browserKey)
          + " [GPU-wrapped variant — flags: ${flagsStr}]";
        mainProgram = newBin;
      };
    };
}
