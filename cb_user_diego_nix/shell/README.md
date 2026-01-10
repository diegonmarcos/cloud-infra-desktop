# Shell Configurations for Nix/Home-Manager

## Structure

```
shell/
├── home.nix          # Full home-manager integration (programs.bash/zsh/fish)
├── home-simple.nix   # Simple file copy approach (avoids escaping issues)
├── bash/
│   └── bashrc        # Bash configuration
├── zsh/
│   ├── zshrc         # Zsh configuration (oh-my-zsh, p10k, aliases, functions)
│   ├── zprofile      # Zsh login profile
│   └── p10k.zsh      # Powerlevel10k theme config
├── fish/
│   ├── config.fish   # Fish configuration
│   ├── fish_plugins  # Fisher plugin list
│   ├── functions/    # Fish functions
│   └── conf.d/       # Fish conf.d scripts
└── profile           # Login shell profile
```

## Usage

### Option 1: Import into your home.nix

```nix
{ config, pkgs, ... }:

{
  imports = [
    ./shell/home.nix        # Full integration
    # OR
    ./shell/home-simple.nix # Just copy files (safer with ASCII art)
  ];

  # ... rest of your config
}
```

### Option 2: Standalone flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations."diego" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./shell/home-simple.nix
          {
            home.username = "diego";
            home.homeDirectory = "/home/diego";
            home.stateVersion = "24.05";
          }
        ];
      };
    };
}
```

### Apply

```bash
# If using flakes
home-manager switch --flake .#diego

# If using channels
home-manager switch
```

## Dependencies

The configs reference these external tools:
- oh-my-zsh
- powerlevel10k
- starship
- wakatime plugin
- rclone (for gdrive mount)

## Notes

- `home-simple.nix` copies files directly - use this if escaping issues occur
- `home.nix` uses `programs.*` modules for deeper integration
- ASCII art and escape sequences are preserved in the raw files
