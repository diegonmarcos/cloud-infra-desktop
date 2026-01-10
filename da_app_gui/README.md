# Flatpak GUI Apps Container

Distrobox-based container with portable GUI applications using Flatpak.

## Applications Included

| Category | Application | Flatpak ID |
|----------|-------------|------------|
| Browser | Brave | `com.brave.Browser` |
| Office | LibreOffice | `org.libreoffice.LibreOffice` |
| Notes | Obsidian | `md.obsidian.Obsidian` |
| Editor | VSCode | `com.visualstudio.code` |
| Files | Dolphin | `org.kde.dolphin` |
| Text | Kate | `org.kde.kate` |
| PDF | Okular | `org.kde.okular` |
| Graphics | Krita | `org.kde.krita` |
| Email | Thunderbird | `org.mozilla.Thunderbird` |
| Chat | Slack | `com.slack.Slack` |
| Music | Spotify | `com.spotify.Client` |
| VPN | ProtonVPN | `com.protonvpn.www` |

## Quick Start

```bash
# Full setup (build, create, export)
./setup.sh all

# Or step by step:
./setup.sh build    # Build container image
./setup.sh create   # Create distrobox
./setup.sh export   # Export apps to host menu
```

## Usage

### Enter the container
```bash
distrobox enter flatpak-box
```

### Run an app directly
```bash
distrobox enter flatpak-box -- flatpak run com.brave.Browser
```

### Add a new flatpak app
```bash
distrobox enter flatpak-box -- flatpak install flathub <app-id>
distrobox enter flatpak-box -- distrobox-export --app <app-id>
```

### Remove an app
```bash
distrobox enter flatpak-box -- flatpak uninstall <app-id>
rm ~/.local/share/applications/flatpak-box-<app-id>.desktop
```

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | Container image definition |
| `docker-compose.yml` | Reference compose file |
| `setup.sh` | Main setup script |
| `export-apps.sh` | Export apps to host |

## Data Persistence

- **App settings**: `~/.var/app/<app-id>/` (shared with host)
- **Flatpak data**: Inside container at `/var/lib/flatpak/`
- **Home directory**: Mounted from host

## Why Distrobox + Flatpak?

1. **Portability**: Same apps work on any Linux (Kubuntu, NixOS, Fedora)
2. **Isolation**: Apps sandboxed from system
3. **Integration**: Seamless desktop integration via distrobox-export
4. **Updates**: `flatpak update` inside container
5. **Rollback**: Flatpak supports app rollback

## Maintenance

```bash
# Update all flatpaks
distrobox enter flatpak-box -- flatpak update

# Check status
./setup.sh status

# Remove everything
./setup.sh remove
```

## Troubleshooting

### Apps not appearing in menu
```bash
./export-apps.sh
update-desktop-database ~/.local/share/applications/
```

### GPU acceleration issues
```bash
# Verify GPU access inside container
distrobox enter flatpak-box -- glxinfo | grep renderer
```

### Sound not working
```bash
# Check PipeWire/PulseAudio socket
ls -la /run/user/$(id -u)/pulse/
```
