#!/usr/bin/env bash
set -u
P5=@p5@
BWRAP=@bwrap@/bin/bwrap
BN=@coreutils@/bin/basename
RL=@coreutils@/bin/readlink

if [ ! -d "$P5/nix/store" ]; then
  echo "@cfgName@: dev-store not present at $P5 — is p5 (/mnt/shared-lib) mounted?" >&2
  exit 1
fi
# The profile gcroot ($P5/profile) points to a LOGICAL /nix/store path that
# only resolves INSIDE the namespace. Resolve the PHYSICAL p5 path so the
# pre-check works outside AND the binaries' interpreter (/nix/store/…-glibc)
# still resolves inside (where /nix/store == the p5 store).
PHYS="$P5/nix/store/$("$BN" "$("$RL" "$P5/profile" 2>/dev/null)" 2>/dev/null)"
if [ ! -x "$PHYS/bin/bash" ]; then
  echo "@cfgName@: dev profile not built yet — run:  ~/git/unix/bc_flakes_dev-store/build.sh ship" >&2
  exit 1
fi

# Host env passes through (no --clearenv) so DISPLAY/WAYLAND_DISPLAY/HOME/TERM
# just work; we only override PATH (→ the p5 profile) and set the marker.
base=( "$BWRAP"
  --dev-bind / /
  --bind "$P5/nix/store" /nix/store
  --setenv @markerEnv@ 1
  --setenv CARGO_HOME "$HOME/.cargo"
  --setenv CARGO_TARGET_DIR "$HOME/.cargo/target"
  --setenv PATH "$PHYS/bin:$HOME/.cargo/bin" )

if [ "${1:-}" = "--" ]; then
  shift
  exec "${base[@]}" "$PHYS/bin/bash" -c 'exec "$@"' _ "$@"
fi

# Interactive: a throwaway rcfile (host /tmp is bound in) sets the [dev] prompt.
RC="$(@coreutils@/bin/mktemp /tmp/dev-rc.XXXXXX)"
printf 'PS1=%s\n' '"@promptMarker@\w \$ "' > "$RC"
"${base[@]}" "$PHYS/bin/bash" --rcfile "$RC" -i
rc=$?
@coreutils@/bin/rm -f "$RC"
exit $rc
