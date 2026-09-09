{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # my-webserver publishes its own package now, including the patchelf and
    # dontStrip handling this module used to carry a copy of. Deliberately NOT
    # `inputs.nixpkgs.follows = "nixpkgs"`: that would hand it 24.05's patchelf
    # 0.15.0, which is the exact build that SIGABRTs on this binary's PT_INTERP
    # and the reason patchelfUnstable had to be plumbed in by hand. It keeps
    # its own unstable pin, which costs a second nixpkgs in a fetch-only
    # closure and buys a binary that runs.
    my-webserver.url = "github:diegonmarcos/cloud-u-linux?dir=da_my-webserver";

    nix-on-droid = {
      # release-24.05 hasn't moved since 2024-07-07 (effectively abandoned) —
      # its fixed-output-derivation binary pins (e.g. proot-termux-static)
      # decayed out of the substituter cache, breaking CI with
      # "path ... does not exist and cannot be created" (2026-07-03).
      # master is actively maintained and has current, fetchable pins.
      url = "github:nix-community/nix-on-droid/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: there used to be a `my-ai` flake input here (github:diegonmarcos/
    # cloud-u-linux?dir=da_my-ai) that claude/claude.nix consumed as a
    # `claudeAssets` OUTPUT for the shared Claude config (agents/,
    # cloud-marketplace/, settings base+overlay). REMOVED 2026-08-21: a
    # pinned flake input only updates on `nix flake update my-ai` + a switch,
    # and the lock sat stale 2026-08-18 to 2026-08-20 while cleanupPeriodDays
    # landed in the SoT — the phone silently deployed pre-fix settings for two
    # days, with no error, and ran on Claude Code's built-in 30-day transcript
    # retention (the mechanism that then swept ~2.5 months of history).
    # claude/claude.nix now reads da_my-ai/data/claude directly from the
    # working checkout AT ACTIVATION TIME (home.activation.claudeAssets /
    # claudeSettingsWritable there) — same fix ba_flakes_desktop already uses.
    # A relative `path:../../da_my-ai` flake input was never an option anyway:
    # nix 2.18 rejects it ("relative path points outside of its parent's
    # store path"), and a `path:` escaping src/ would copy the whole ~3.6GB
    # repo into the store and kill proot mid-copy.
  };

  outputs = { self, nixpkgs, nixpkgs-new, nixpkgs-unstable, nix-on-droid, home-manager, my-webserver }:
    let
      pkgsNew = import nixpkgs-new { system = "aarch64-linux"; };
      pkgsUnstable = import nixpkgs-unstable { system = "aarch64-linux"; config.allowUnfree = true; };

      # Node identity for DTK webhooks (ntfy topic = dtk-cmd-<dtkNode>).
      # Source of truth: build.json -> defaults.dtk_node. Termux can't
      # sethostname() on Android (no root) so `hostname -s` returns
      # "localhost" — useless as a topic key. This makes the identity
      # declarative + data-driven instead.
      # ./build.json is vendored into src/ by build.sh before eval — the flake
      # must reference nothing outside src/ (path: flake; a ../ ref escaping src/
      # forces nix to copy the whole 3.6GB repo and proot dies mid-copy).
      buildJson = builtins.fromJSON (builtins.readFile ./build.json);
      dtkNode = buildJson.defaults.dtk_node or "unset";

      # THE ONE VALUE. Every path this flake writes on the device and every
      # Android intent it sends is namespaced by the application id of the
      # terminal being activated INTO: /data/data/<id>/files/{home,usr}. Until
      # 2026-09-09 that id was spelled out by hand 31 times across seven files
      # under src/, and pinned in two readOnly options by the nix-on-droid
      # input that no module of ours could redefine, so this flake could only
      # ever activate inside com.termux.nix. Home Manager's checkHomeDirectory
      # aborts the activation when $HOME is not the eval-time home.homeDirectory
      # (lib-bash/activation-init.sh), so a switch run inside the renamed fork
      # cld.termux.nix died before linkGeneration and that app got NO
      # configuration at all -- no ~/.termux/termux.properties, so its
      # RunCommandService refused the boot companion's intent with
      # "allow-external-apps is not set to true" and nothing auto-started at boot.
      # No `or` fallback on either: a build.json that has lost these keys must
      # fail the eval, not quietly target one app. A default here would be a
      # second place the id lives, which is the whole defect being removed.
      androidPackageDefault = buildJson.defaults.android_package;
      androidPackages = buildJson.defaults.android_packages;

      # ONE nerdfonts derivation shared by environment.packages and the
      # ~/.termux/font.ttf home.file (two different `override` calls used to
      # build two separate huge packages).
      jbMonoNerd = (import nixpkgs { system = "aarch64-linux"; }).nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; };

      # Build termux-am from nix-on-droid source (provides `am` for Android intents)
      termux-am = (import nixpkgs { system = "aarch64-linux"; }).callPackage
        "${nix-on-droid}/pkgs/android-integration/termux-am.nix" {};

      # bash + zsh aliases, DERIVED from the same single source of truth the
      # fish layer uses (modules/data/fish-commands.json, entries flagged
      # shared:true). Hand-keeping a second copy here is what produced the
      # `up` shadow that hid the managed fish function for months.
      # fish is NOT fed from here — fish.nix owns the full set — so the two
      # definitions can never collide on a key.
      fishCmds = builtins.fromJSON (builtins.readFile ./modules/data/fish-commands.json);
      sharedAliases = builtins.listToAttrs (map
        (a: { name = a.name; value = a.cmd; })
        (builtins.filter (a: a.shared or false) fishCmds.aliases));

      # ONE builder, parameterised by the application id -- never a second copy
      # of the module list with a different string in it. Every instance
      # therefore gets byte-identical declarations (including the
      # allow-external-apps line in modules/cloud-ide-sshd) and no instance can
      # silently drift away from the others.
      mkTermuxConfiguration = androidPackage: nix-on-droid.lib.nixOnDroidConfiguration {
        pkgs = import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
        modules = [
          # Plain attrset, NOT a function: disabledModules is read before module
          # arguments exist, so naming `nix-on-droid` through a module argument
          # here would recurse forever. See modules/android-package.nix for why
          # the upstream module has to go rather than merely be overridden.
          {
            disabledModules = [
              "${nix-on-droid}/modules/user.nix"
              "${nix-on-droid}/modules/build/config.nix"
            ];
          }
          ({ config, lib, pkgs, ... }: {
            imports = [
              ./modules/android-package.nix
              ./modules/system.nix
              ./modules/environment-packages.nix
            ];

            # Derived in the outer `let` and handed to the imported system modules.
            _module.args = {
              inherit pkgsNew pkgsUnstable termux-am jbMonoNerd dtkNode nix-on-droid;
              inherit androidPackage;
            };

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { config, pkgs, lib, ... }: {
              _module.args.nodejs = pkgsUnstable.nodejs_22;
              # wstunnel 7.x (Rust) lives in pkgsUnstable. The old wstunnel 0.5.x
              # in pinned nixos-24.05 is Haskell and pulls connection-0.3.1 which
              # is marked broken upstream — blocking every home-manager switch.
              _module.args.wstunnel = pkgsUnstable.wstunnel;
              # patchelf 0.15.0 (pinned nixos-24.05) crashes with
              # "Assertion !section.empty() failed" rewriting the interpreter
              # on large (~70MB+) binaries that are already nix-patched —
              # exactly what the fetched my-webserver blob
              # is (patched once already by the CI job that publishes it, at
              # a different glibc store path than this flake's own pin).
              # Fixed in later patchelf releases; pkgsUnstable has one.
              _module.args.myWebserverPkg = my-webserver.packages.aarch64-linux.my-webserver-bin;
              # claude/claude.nix reads the Claude config straight from the
              # working checkout at activation time now — no flake-input arg
              # needed. See the my-ai NOTE in this file's inputs block.
              # Derived in the outer `let` (one shared nerdfonts derivation; aliases
              # generated from modules/data/fish-commands.json).
              # `am` for Android intents. cloud-ide-sshd needs it to take a wake
              # lock: Doze reaps proot children, and no other start path here
              # runs without a human already holding the phone. Declared for HM
              # separately because the _module.args above only reach the system
              # modules.
              _module.args.termux-am = termux-am;
              _module.args.jbMonoNerd = jbMonoNerd;
              _module.args.sharedAliases = sharedAliases;
              # The application id and the Termux prefix derived from it. The
              # _module.args above only reach the system modules, and these are
              # what stop each Home Manager module re-typing the id by hand. The
              # matching home path is config.home.homeDirectory, which
              # modules/android-package.nix pins from this same value.
              _module.args.androidPackage = androidPackage;
              _module.args.termuxPrefix = "/data/data/${androidPackage}/files/usr";

              imports = [
                ./claude/claude.nix
                ./modules/termux-platform.nix
                ./modules/hm-runtime.nix
                ./modules/gemini.nix
                ./modules/common.nix
                ./modules/packages.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-npm-deps.nix
                ./modules/node-bins.nix
                ./modules/my-webserver
                ./modules/cloud-ide-sshd
                ./modules/wireguard.nix
                ./modules/wireguard-wstunnel.nix
              ];
              home.stateVersion = "24.05";

            };
          })
        ];
      };
    in
    {
      # One entry per declared instance, plus `default` for the callers that
      # cannot name one (CI, and `nix-on-droid switch --flake path:src`). Adding
      # a terminal is a build.json edit, never a new module tree.
      #
      # Dots become dashes in the attribute name, and that is load-bearing:
      # nix-on-droid's own CLI rewrites `--flake <uri>#<name>` into
      # `<uri>#nixOnDroidConfigurations.<name>` with no quoting (see
      # nix-on-droid.sh), so an attribute literally called "cld.termux.nix"
      # would be parsed as three nested attributes and fail with "attribute
      # 'cld' missing". The transform is mechanical, so the id stays the only
      # thing anyone writes down.
      nixOnDroidConfigurations =
        { default = mkTermuxConfiguration androidPackageDefault; }
        // builtins.listToAttrs (map
          (p: {
            name = builtins.replaceStrings [ "." ] [ "-" ] p;
            value = mkTermuxConfiguration p;
          })
          androidPackages);

      # ── termux-cache-image: LAYERED image of the nix-on-droid closure ──
      # One layer per store path (dockerTools.buildLayeredImage) → skopeo
      # (no Docker daemon needed on Android — see build.sh's
      # ghcr_pull_layered_skopeo) skips unchanged layers, so `build.sh pull`
      # fetches only the store paths that actually changed instead of
      # re-downloading the whole multi-GB nar. Pushed to GHCR by the CI
      # export step (GHCR_PUSH=1); consumed by `cmd_pull` (the nar.zst path
      # is kept as the fallback). Mirrors ba_flakes_desktop's hm-cache-image.
      packages.aarch64-linux.termux-cache-image = pkgsNew.dockerTools.buildLayeredImage {
        name = "unix-termux-cache";
        tag = "latest";
        maxLayers = 120;
        contents = [ self.nixOnDroidConfigurations.default.activationPackage ];
        config.Labels = {
          "org.opencontainers.image.description" = "Termux (nix-on-droid) activation closure as layered store paths (incremental GHCR cache).";
          "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-infra-desktop";
        };
      };
    };
}
