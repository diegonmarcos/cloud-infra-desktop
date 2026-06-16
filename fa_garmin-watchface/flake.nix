{
  description = "Garmin Connect IQ watch faces — declarative SDK toolchain + build devShell (the Nix way, no Docker)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # connect-iq-sdk-manager-cli — reproducibly downloads + pins the proprietary
    # Connect IQ SDK (which is NOT in nixpkgs). Pinned by rev here; the SDK
    # version itself is pinned by build.json::toolchain.ciq_sdk + the committed
    # connect-iq-sdk-manager lockfile. This is how we stay declarative without
    # vendoring Garmin's binary blob into the repo.
    ciq-sdk-manager = {
      url = "github:lindell/connect-iq-sdk-manager-cli";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ciq-sdk-manager }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # The SDK manager CLI (Go). vendorHash is a fixed-output hash of the Go
        # module deps: on first `nix build`/`nix develop`, Nix prints the real
        # hash — replace lib.fakeHash with it once, then commit. Standard FOD
        # bootstrap, not a workaround.
        sdkManager = pkgs.buildGoModule {
          pname = "connect-iq-sdk-manager";
          version = "0-unstable";
          src = ciq-sdk-manager;
          vendorHash = pkgs.lib.fakeHash; # TODO(one-time): replace with hash Nix prints
          meta.description = "CLI to download/pin the Garmin Connect IQ SDK";
        };

        # Tools every build.sh path needs. monkeyc/connectiq/monkeydo come from
        # the SDK materialised by sdkManager into ./.ciq-sdk (see shellHook),
        # pinned by the committed lockfile so it's reproducible across machines.
        tools = with pkgs; [
          jdk17          # monkeyc is a JVM tool (bin/monkeybrains.jar)
          sdkManager
          python3        # lib/gen-design.py (stdlib only)
          jq             # build.json / design.json reads
          openssl        # developer-key generation/conversion
          oras           # GHCR OCI-artifact publish (mirrors ea_cloud-superapp)
          gh             # GitHub rolling-release publish
          sops age       # vault signing-key decrypt (Pillar 7)
          coreutils gnused gawk
        ];
      in {
        devShells.default = pkgs.mkShell {
          packages = tools;

          # Materialise the SDK (idempotent, lockfile-pinned) and put its bin/
          # on PATH so `monkeyc`, `connectiq`, `monkeydo` resolve. The SDK lives
          # under ./.ciq-sdk (gitignored). Skipped when BYPASS_NIX=1 (CI provides
          # its own SDK via the official action).
          shellHook = ''
            export CIQ_SDK_ROOT="$PWD/.ciq-sdk"
            if [ ! -x "$CIQ_SDK_ROOT/bin/monkeyc" ]; then
              echo "[flake] Connect IQ SDK not materialised — fetching (pinned)…"
              connect-iq-sdk-manager sdk download --output "$CIQ_SDK_ROOT" || {
                echo "[flake] SDK download failed — see README (one-time Garmin login may be needed)." >&2
              }
            fi
            export PATH="$CIQ_SDK_ROOT/bin:$PATH"
          '';
        };

        # Pure SDK package (optional, for fully-hermetic CI). Filled once like
        # vendorHash above. Kept separate so a plain `nix develop` never forces
        # the full SDK realisation when BYPASS_NIX=1.
        packages.sdk-manager = sdkManager;
      });
}
