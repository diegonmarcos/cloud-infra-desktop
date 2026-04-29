# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║          SURFACE PRO 8 — COMPLETE DECLARATIVE INFRASTRUCTURE             ║
# ║                                                                           ║
# ║   This file is the single source of truth for the entire unix/ repo.     ║
# ║   It declares: hardware, disk layout, OS installations, boot chain,      ║
# ║   containers, home-manager flakes, and Ventoy USB recovery images.       ║
# ║                                                                           ║
# ║   NOT meant to be `terraform apply`d — it's a declarative spec that      ║
# ║   documents and validates the system state. Each resource maps to a      ║
# ║   real build.sh or install.sh in the repo.                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.5"
}

# ═══════════════════════════════════════════════════════════════════════════════
# VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════

variable "owner" {
  default = "Diego Nepomuceno Marcos"
}

variable "device" {
  default = "Surface Pro 8"
}

variable "nvme_device" {
  default = "/dev/nvme0n1"
}

variable "nvme_size_gb" {
  default = 256
}

# ═══════════════════════════════════════════════════════════════════════════════
# A. HARDWARE — Surface Pro 8
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  hardware = {
    cpu = {
      model    = "Intel Core i7-1185G7"
      clock    = "3.00GHz"
      arch     = "x86_64"
      codename = "Tiger Lake"
      features = ["kvm-intel", "aes-ni"]
    }
    ram = {
      size_gb = 16
    }
    storage = {
      type     = "NVMe SSD"
      size_gb  = 256
      device   = "/dev/nvme0n1"
    }
    display = {
      size       = "13 inch"
      resolution = "2880x1920"
      type       = "PixelSense"
      touch      = true
    }
    gpu = {
      model  = "Intel Iris Xe Graphics"
      driver = "i915"
    }
    peripherals = {
      keyboard  = "Type Cover (requires surface_aggregator + surface_hid)"
      pen       = "Surface Pen (MPP 2.0)"
      touch     = "iptsd (libwacom-surface)"
      webcam    = "Intel IPU6 (requires Windows driver — see ac_win11_webcam)"
      wifi      = "Intel WiFi 6 AX201"
      bluetooth = "Intel Bluetooth 5.2"
    }
    kernel = {
      type    = "linux-surface"
      source  = "github:linux-surface/linux-surface"
      nixos   = "nixos-hardware.nixosModules.microsoft-surface-pro-intel"
      version = "stable (latest patched release)"
    }
    initrd_modules = {
      bus_power = [
        "intel_lpss", "intel_lpss_pci",
        "8250_dw", "pinctrl_tigerlake", "xhci_pci",
      ]
      surface = [
        "surface_aggregator", "surface_aggregator_registry", "surface_aggregator_hub",
        "surface_hid_core", "surface_hid",
      ]
      input_fallback = [
        "hid_multitouch", "hid_generic",
        "i2c_hid", "i2c_hid_acpi",
      ]
      storage = [
        "xhci_pci", "thunderbolt", "nvme", "usb_storage", "sd_mod", "uas",
        "btrfs", "dm-snapshot",
      ]
      usb_keyfile = [
        "vfat", "fat", "nls_cp437", "nls_iso8859-1", "nls_utf8",
      ]
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# B. DISK LAYOUT — GPT Partition Table
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  partitions = {
    # ─── Non-Encrypted Zone (~50GB) ─────────────────────────────────────────
    p1_efi = {
      device     = "nvme0n1p1"
      size       = "100MB"
      type       = "EFI System"
      filesystem = "FAT32"
      uuid       = "2CE0-6722"
      mount      = "/boot/efi"
      purpose    = "EFI System Partition (GRUB)"
    }
    p2_boot = {
      device     = "nvme0n1p2"
      size       = "2GB"
      type       = "Linux"
      filesystem = "ext4"
      uuid       = "0eaf7961-48c5-4b55-8a8f-04cd0b71de07"
      mount      = "/boot"
      purpose    = "Shared /boot — kernels + initrd for NixOS + Kubuntu"
    }
    p3_alpine = {
      device     = "nvme0n1p3"
      size       = "5GB"
      type       = "Linux"
      filesystem = "ext4"
      uuid       = null # TBD
      mount      = "/recovery"
      purpose    = "Alpine Linux recovery OS (always accessible)"
    }
    p4_kali = {
      device     = "nvme0n1p4"
      size       = "~20GB"
      type       = "Linux"
      filesystem = "ext4"
      uuid       = "509491e4-d3a7-426d-9b78-4b024b24cc32"
      mount      = null
      purpose    = "Kali Linux — penetration testing, isolated from LUKS"
    }
    p5_windows = {
      device     = "nvme0n1p5"
      size       = "~20GB"
      type       = "Microsoft"
      filesystem = "NTFS"
      uuid       = null # TBD
      mount      = null
      purpose    = "Windows 11 Lite — webcam driver only (OBS→NDI→v4l2loopback)"
    }

    # ─── LUKS Encrypted Zone (~180GB) ───────────────────────────────────────
    p6_luks = {
      device     = "nvme0n1p6"
      size       = "~180GB"
      type       = "LUKS2"
      filesystem = "LUKS2 → BTRFS"
      uuid       = "3c75c6db-4d7c-4570-81f1-02d168781aac"
      mapper     = "/dev/mapper/pool"
      purpose    = "Encrypted BTRFS pool — all persistent data"
      unlock = {
        primary  = "USB keyfile: /usb-key/.luks/surface.key (4096 bytes)"
        fallback = "Password prompt (5s timeout)"
        usb_uuid = "223C-F3F8"
        usb_path = "VTOYEFI/.luks/surface.key"
      }
    }

    # ─── Kubuntu (ext4, separate partition) ─────────────────────────────────
    kubuntu = {
      device     = "separate partition"
      filesystem = "ext4"
      uuid       = "7e3626ac-ce13-4adc-84e2-1a843d7e2793"
      mount      = "/mnt/kubuntu (ro, nofail)"
      purpose    = "Kubuntu dual-boot — secondary desktop OS"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# C. BTRFS SUBVOLUME LAYOUT (inside LUKS pool)
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  btrfs_pool = {
    device      = "/dev/mapper/pool"
    compression = "zstd"
    options     = ["compress=zstd", "noatime"]

    subvolumes = {
      # ─── System (OS-managed, declarative) ─────────────────────────────────
      "@nixos/nix" = {
        mount           = "/nix"
        purpose         = "Nix store (immutable packages)"
        size_estimate   = "30-50GB"
        needed_for_boot = true
      }

      # ─── User Homes (per-user, detachable) ────────────────────────────────
      "@home-diego" = {
        mount         = "/home/diego"
        purpose       = "Diego's home directory"
        size_estimate = "20-50GB"
        nofail        = true
      }
      "@home-guest" = {
        mount         = "/home/guest"
        purpose       = "Guest user home"
        size_estimate = "5-10GB"
        nofail        = true
      }
      "@home-diego/waydroid" = {
        mount         = "/home/diego/.local/share/waydroid"
        purpose       = "Waydroid per-user data (Diego)"
        nofail        = true
      }
      "@home-guest/waydroid" = {
        mount         = "/home/guest/.local/share/waydroid"
        purpose       = "Waydroid per-user data (Guest)"
        nofail        = true
      }

      # ─── Shared Resources ─────────────────────────────────────────────────
      "@shared" = {
        mount         = "/mnt/shared"
        purpose       = "Common storage for all OSes"
        size_estimate = "varies"
        nofail        = true
      }
      "@shared/waydroid-base" = {
        mount         = "/var/lib/waydroid"
        purpose       = "Waydroid base images (shared between users)"
        size_estimate = "5-10GB"
        nofail        = true
      }
    }

    # Root is tmpfs (impermanence) — wiped every boot
    root = {
      device  = "none"
      fstype  = "tmpfs"
      options = ["defaults", "size=2G", "mode=755"]
    }

    # Btrfs root view (all subvolumes)
    btrfs_root = {
      mount   = "/mnt/btrfs-root"
      options = ["subvolid=5"]
      nofail  = true
    }
  }

  swap = {
    type     = "file"
    path     = "/mnt/shared/.swapfile"
    size     = "8GB"
    zram     = false  # Using file swap, not zram currently
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# D. BOOT CHAIN — GRUB + Multi-OS
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  boot = {
    loader = "GRUB"
    efi = {
      mount                 = "/boot/efi"
      can_touch_variables   = true
      install_as_removable  = false
    }
    default_entry = 0  # NixOS

    grub_entries = {
      "0_nixos" = {
        name   = "NixOS"
        type   = "native"
        note   = "Primary OS — managed by nixos-rebuild"
      }
      "1_kubuntu" = {
        name   = "Kubuntu OS"
        type   = "linux"
        kernel = "/vmlinuz-6.18.2-surface-1"
        root   = "UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793"
      }
      "2_arch" = {
        name   = "Arch OS"
        type   = "linux"
        kernel = "/boot/vmlinuz-linux-surface"
        root   = "UUID=1648a2fb-f2ce-4da5-9966-645758a24929"
      }
      "3_kali" = {
        name   = "Kali Linux"
        type   = "linux"
        kernel = "/vmlinuz"
        root   = "UUID=509491e4-d3a7-426d-9b78-4b024b24cc32"
      }
      "4_windows" = {
        name   = "Windows Boot Manager"
        type   = "chainloader"
        path   = "/EFI/Microsoft/Boot/bootmgfw.efi"
      }
      "5_usb_uefi" = {
        name = "Boot from USB (UEFI)"
        type = "chainloader"
        path = "/EFI/BOOT/BOOTX64.EFI"
      }
      "6_ventoy" = {
        name = "Boot from Ventoy USB"
        type = "chainloader"
        uuid = "223C-F3F8"
        path = "/EFI/BOOT/BOOTX64.EFI"
      }
      "7_firmware" = {
        name = "UEFI Firmware Settings"
        type = "fwsetup"
      }
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# E. OPERATING SYSTEMS — Installed on Disk
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  os_installed = {
    # ─── aa: NixOS (Primary) ────────────────────────────────────────────────
    nixos = {
      repo_path    = "aa_nixos-surface_host"
      partition    = "p6_luks (BTRFS subvolumes)"
      version      = "NixOS 24.11"
      kernel       = "linux-surface (stable)"
      flake_inputs = ["nixpkgs/nixos-24.11", "nixos-hardware", "nixos-generators"]
      desktop      = "KDE Plasma 6 (Wayland)"
      display_mgr  = "SDDM"
      root         = "tmpfs (impermanence)"
      encryption   = "LUKS2 (USB keyfile + password)"
      build_cmd    = "./build.sh"  # Cmds: s|switch  b|boot  t|test  c|check  u|update  d|diff  i|install  build {raw|iso|qcow|vm}  burn  (no arg = TUI)

      sessions = [
        "01-plasma    — KDE Plasma (Wayland, default)",
        "02-gnome     — GNOME (Wayland)",
        "03-android   — Waydroid in Cage",
        "04-chrome-kiosk — Chromium kiosk",
        "05-tor-kiosk — Tor Browser kiosk",
        "06-openbox   — Openbox (X11)",
        "07-gnome-kiosk — GNOME locked-down",
      ]

      build_outputs = {
        oci_image = "Docker/OCI image"
        raw       = "Raw disk image (48GB, EFI)"
        iso       = "Install ISO (live, squashfs)"
        vm        = "QEMU VM for testing"
      }

      users = {
        diego = {
          groups = ["wheel", "networkmanager", "video", "input", "audio",
                    "docker", "libvirtd", "scanner", "lp", "dialout"]
          shell  = "fish"
          sudo   = "NOPASSWD"
        }
        guest = {
          groups = ["video", "input", "audio", "networkmanager"]
          shell  = "fish"
          sudo   = false
        }
      }
    }

    # ─── ab: Kubuntu (Dual-boot) ────────────────────────────────────────────
    kubuntu = {
      partition   = "UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793"
      filesystem  = "ext4"
      version     = "Kubuntu (linux-surface kernel)"
      kernel      = "6.18.2-surface-1"
      desktop     = "KDE Plasma"
      encryption  = "none"
      purpose     = "Secondary desktop OS, fallback"
      mount_from_nixos = "/mnt/kubuntu (ro, nofail)"
    }

    # ─── ab: Arch (Fallback Desktop) ────────────────────────────────────────
    arch = {
      repo_path   = "ab_arch-surface_fallback_desk"
      partition   = "UUID=1648a2fb-f2ce-4da5-9966-645758a24929"
      filesystem  = "ext4"
      version     = "Arch Linux (rolling)"
      kernel      = "linux-surface"
      desktop     = "Openbox + Sway"
      encryption  = "none"
      purpose     = "Fallback desktop with direct hardware access"
      install     = "install.json + install.sh"

      packages = {
        surface  = ["linux-surface", "linux-surface-headers", "iptsd"]
        shells   = ["bash", "zsh", "fish"]
        gui      = ["xorg-server", "openbox", "sway", "pcmanfm"]
        dev      = ["nodejs", "npm", "python", "python-pip"]
        cli      = ["ripgrep", "fd", "fzf", "jq", "eza", "bat", "zoxide"]
        ai       = ["@anthropic-ai/claude-code"]
      }
    }

    # ─── ab: Kali (Security) ────────────────────────────────────────────────
    kali = {
      repo_path   = "ab_kali_security"
      partition   = "nvme0n1p4 (~20GB ext4)"
      uuid        = "509491e4-d3a7-426d-9b78-4b024b24cc32"
      version     = "Kali Linux"
      kernel      = "kali default"
      encryption  = "none (intentional — isolation from LUKS)"
      purpose     = "Penetration testing, security auditing"
      install     = "debootstrap + SETUP.md"

      isolation = [
        "NO access to nvme0n1p6 (LUKS encrypted)",
        "NO access to NixOS /nix store",
        "NO access to user vault",
        "Separate network namespace (optional)",
      ]
    }

    # ─── ac: Windows 11 (Webcam) ────────────────────────────────────────────
    windows = {
      repo_path   = "ac_win11_webcam"
      partition   = "nvme0n1p5 (~20GB NTFS)"
      version     = "Windows 11 Lite (debloated)"
      encryption  = "none"
      purpose     = "Surface webcam driver — OBS→NDI→v4l2loopback→NixOS"
      install     = "SETUP.md (manual)"

      pipeline = "Surface Webcam → OBS Studio → NDI/RTSP → ffmpeg → v4l2loopback (/dev/video10)"
    }

    # ─── ae: BlissOS/Samsung (Mobile) ───────────────────────────────────────
    mobile = {
      repo_path = "ae_mobile_image"
      type      = "QEMU VM"
      purpose   = "BlissOS (Android x86) VM + Samsung app migration"
      install   = "run-qemu.sh, setup.sh"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# F. VENTOY USB — Recovery Boot Images
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  ventoy_usb = {
    repo_path = "ad_ventoy_fallback_usb"
    usb_uuid  = "223C-F3F8"

    config = {
      display_mode  = "GUI"
      gfx_mode      = "1920x1280"
      menu_timeout  = 10
    }

    luks_keys = {
      surface_key = "VTOYEFI/.luks/surface.key"
      vault_key   = "VTOYEFI/.vault/vault.key (optional)"
    }

    images = {
      nixos_slim = {
        path           = "nixos-surface-slim"
        os             = "NixOS 24.11"
        kernel         = "linux-surface (nixos-hardware)"
        size           = "~600-700MB"
        window_manager = "Openbox"
        shell          = "fish"
        packages       = ["vim", "nano", "btop", "ripgrep", "fzf", "jq", "tmux", "nodejs"]
        ai_tools       = ["claude-code"]
        services       = ["NetworkManager", "sshd", "iptsd"]
        boot_modes     = ["normal", "copytoram"]
        build_cmd      = "./build.sh"
        install        = "install.json"
      }

      arch_recovery = {
        path           = "a_arch-surface_fallback_usb"
        os             = "Arch Linux (rolling)"
        kernel         = "linux-surface"
        window_manager = "Openbox + Sway"
        shell          = "fish"
        packages       = ["ripgrep", "fd", "fzf", "jq", "eza", "bat", "zoxide", "nodejs"]
        ai_tools       = ["claude-code"]
        services       = ["NetworkManager", "sshd", "iptsd"]
        build_cmd      = "./build_live.sh"
        install        = "install.json + install.sh"
      }

      alpine_recovery = {
        path           = "alpine_fallback_usb"
        os             = "Alpine 3.21"
        kernel         = "linux-lts"
        window_manager = "Openbox"
        shell          = "fish"
        packages       = ["ripgrep", "fd", "fzf", "jq", "tmux", "nodejs"]
        ai_tools       = ["claude-code", "gemini-cli"]
        services       = ["dbus", "networkmanager", "sshd"]
        build_cmd      = "./build.sh"
        install        = "install.json + install.sh"
      }

      debian_recovery = {
        path           = "debian-slim-surface_fallback_usb"
        os             = "Debian Bookworm (12)"
        kernel         = "6.18.2-surface-1"
        size           = "~676MB"
        ram_toram      = "~3.2GB"
        window_manager = "Openbox"
        shell          = "fish"
        packages       = ["ripgrep", "jq", "fzf", "tmux", "btop", "nodejs"]
        ai_tools       = ["claude-code"]
        services       = ["NetworkManager", "iptsd"]
        build_cmd      = "./build_live.sh"
        install        = "install.json"
      }
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# G. HOME-MANAGER FLAKES
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  home_manager = {
    desktop = {
      repo_path = "ba_flakes_desktop"
      target    = "NixOS / any Linux desktop"
      shell     = "fish"
      build_cmd = "./build.sh"
      manages   = [
        "Shell configs (fish, zsh, bash, starship)",
        "Editor configs (vim, neovim)",
        "Git config",
        "Claude Code config (~/.claude/)",
        "Desktop dotfiles",
      ]
    }

    termux = {
      repo_path = "bb_flakes_termux"
      target    = "Android (Termux / nix-on-droid)"
      shell     = "zsh"
      build_cmd = "./build.sh"
      manages   = [
        "Shell configs (zsh, bash, starship)",
        "Editor configs (vim)",
        "Git config",
        "Claude Code config (~/.claude/)",
        "MCP server configs (~/.mcp.json)",
        "SSH config",
        "Termux-specific tools (sops, age, oci, gcloud, gh)",
      ]
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# H. CONTAINERS — Podman (new: ca_ and cb_)
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  containers = {
    cli_dev = {
      repo_path  = "ca_container_cli"
      image      = "cli-dev:latest"
      engine     = "podman"
      base       = "Fedora 41"
      build_cmd  = "./build.sh build"
      compose    = "podman-compose.yml"

      categories = {
        shells     = ["bash", "zsh", "fish"]
        compilers  = ["gcc", "g++", "cmake", "ninja", "meson", "rust", "cargo", "golang", "java-21", "ruby"]
        languages  = ["python3", "poetry", "nodejs", "npm"]
        debuggers  = ["gdb", "valgrind", "strace", "ltrace"]
        modern_cli = ["eza", "bat", "fd-find", "ripgrep", "fzf", "jq", "yq", "zoxide", "starship", "btop", "ncdu"]
        editors    = ["nano", "vim", "neovim"]
        network    = ["curl", "wget", "rsync", "nmap", "mtr", "openssh"]
        privacy    = ["tor", "torsocks", "dnscrypt-proxy", "wireguard-tools", "openvpn"]
        cloud_cli  = ["gh", "oci-cli (pip)", "gcloud (manual)"]
        ai_tools   = ["claude-code (npm)", "gemini-cli (npm)"]
        file_sync  = ["rsync", "rclone"]
        docs       = ["pandoc", "graphviz"]
      }

      volumes = {
        home     = "cli-dev-home:/home/user"
        projects = "$HOME/git:/home/user/git"
        ssh      = "SSH_AUTH_SOCK forwarding"
      }
    }

    gui_apps = {
      repo_path  = "cb_container_gui"
      image      = "gui-apps:latest"
      engine     = "podman"
      base       = "Fedora 41"
      build_cmd  = "./build.sh build"
      compose    = "podman-compose.yml"

      native_apps = ["konsole", "dolphin", "okular", "krita", "filelight", "virt-manager"]

      flatpak_apps = {
        browsers     = ["com.brave.Browser"]
        office       = ["org.libreoffice.LibreOffice", "md.obsidian.Obsidian"]
        development  = ["com.visualstudio.code"]
        communication = ["org.mozilla.Thunderbird", "com.slack.Slack"]
        media        = ["com.spotify.Client"]
        vpn          = ["com.protonvpn.www"]
      }

      desktop = {
        x11     = "xorg-x11-server-Xorg + openbox + dmenu"
        vnc     = "x11vnc (port 5900)"
        fonts   = "dejavu-fonts-all"
        icons   = "breeze-icon-theme"
        network = "host"
      }

      passthrough = {
        display = "X11 + Wayland"
        audio   = "PipeWire/PulseAudio"
        gpu     = "/dev/dri"
        dbus    = "/run/dbus (ro)"
      }
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# I. NETWORK & SECURITY — "VPS-level" rules
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  network = {
    hostname = "surface-nixos"

    # ─── Interfaces ──────────────────────────────────────────────────────────
    interfaces = {
      wifi = {
        driver  = "iwd + NetworkManager"
        device  = "Intel WiFi 6 AX201"
        managed = true
      }
      wg0 = {
        type        = "WireGuard"
        ip          = "10.0.0.5/24"
        private_key = "/home/diego/.config/wireguard/privatekey"
        autostart   = false  # on-demand, wantedBy = mkForce []
        peers = [
          {
            name       = "gcp-proxy"
            endpoint   = "35.226.147.64:51820"
            public_key = "(in vault)"
            allowed_ips = ["10.0.0.0/24"]
            persistent_keepalive = 25
          }
        ]
      }
    }

    # ─── Firewall (nftables via NixOS networking.firewall) ───────────────────
    firewall = {
      enabled = true
      backend = "nftables (NixOS default)"

      inbound_allow_tcp = [22]   # SSH only
      inbound_allow_udp = []     # Nothing
      inbound_default   = "DROP"

      # Outbound: unrestricted (workstation, not server)
      outbound_default = "ACCEPT"

      notes = [
        "No web server ports — this is a workstation, not a server",
        "WireGuard (wg0) traffic traverses the tunnel, not the firewall",
        "Container ports (5900/VNC) are localhost-only via podman compose",
        "Kali partition has its own network stack (separate OS, no shared rules)",
      ]
    }

    # ─── SSH Server ──────────────────────────────────────────────────────────
    ssh = {
      enabled                 = true
      port                    = 22
      password_authentication = true   # Acceptable for personal LAN device
      permit_root_login       = "no"
      pubkey_authentication   = true
      host_keys               = "ephemeral (tmpfs root — regenerated each boot)"

      authorized_users = {
        diego = {
          groups = ["wheel"]
          sudo   = "NOPASSWD"
          keys   = "~/.ssh/authorized_keys (from vault)"
        }
      }

      hardening_notes = [
        "Host keys are ephemeral (tmpfs root) — clients see new fingerprint after reboot",
        "To persist: symlink from @shared/ssh/ via tmpfiles (not currently done)",
        "PasswordAuthentication=true is intentional — LAN-only device, no public IP",
        "If exposed to internet: switch to pubkey-only + fail2ban",
      ]
    }

    # ─── VPN Mesh (WireGuard to cloud VMs) ───────────────────────────────────
    vpn = {
      type    = "WireGuard"
      network = "10.0.0.0/24"
      role    = "client (on-demand)"

      mesh_peers = {
        "10.0.0.1" = "gcp-proxy   (Caddy, Authelia, Vaultwarden, ntfy, DNS)"
        "10.0.0.2" = "oci-apps-1  (PhotoPrism, NocoDB, Code Server, AFFiNE)"
        "10.0.0.3" = "oci-mail    (Mailu, Syncthing, Radicale)"
        "10.0.0.4" = "oci-analytics (Matomo)"
        "10.0.0.5" = "surface     (THIS DEVICE)"
        "10.0.0.6" = "oci-apps    (C3 API, Crawlee)"
      }

      notes = [
        "Surface is NOT always-on — wg0 started manually when needed",
        "All cloud traffic routes: Surface → wg0 → gcp-proxy → target VM",
        "DNS over WireGuard: Hickory DNS at 10.0.0.1:53 (wg-only)",
      ]
    }

    # ─── DNS ──────────────────────────────────────────────────────────────────
    dns = {
      resolver = "NetworkManager (system default)"
      internal = "Hickory DNS at 10.0.0.1 (via WireGuard, when connected)"
      external = "Cloudflare DNS for *.diegonmarcos.com"
    }
  }

  # ─── Resource Limits (cgroups v2 — "The Bouncer") ────────────────────────
  resource_limits = {
    system_slice = {
      memory_min = "500M"
      cpu_weight = 10000
      note       = "systemd, sshd, docker daemon — guaranteed minimum"
    }
    user_slice = {
      memory_max = "90%"
      note       = "All user sessions capped; compositor gets MemoryMin guarantee"
    }
    machine_slice = {
      memory_max = "50%"
      note       = "docker/podman containers capped"
    }
    nix_daemon = {
      memory_max = "70%"
      cpu_quota  = "50%"
      note       = "Nix builds don't starve the desktop"
    }
    oom = {
      earlyoom  = true
      zram_swap = "zstd, 50% of RAM"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# J. OPS & MISC
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  ops = {
    claude_sandbox = {
      repo_path = "de_claude-sandbox"
      purpose   = "Claude Code sandboxed AppImage build"
    }
  }

  archived = {
    path = "z_archive"
    contents = [
      "0_spec         — old spec files",
      "a_kinoite_host — Fedora Kinoite host (abandoned)",
      "da_app_cli     — old CLI container (→ ca_container_cli)",
      "da_app_gui     — old GUI container (→ cb_container_gui)",
      "db_apps_gui_2  — old unified builder (→ ca_ + cb_)",
      "dd_ops_scripts — mount + sync scripts",
    ]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# K. STORAGE BUDGET
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  storage_budget = {
    non_encrypted = {
      efi     = { min = "100MB", max = "100MB" }
      boot    = { min = "2GB",   max = "2GB" }
      alpine  = { min = "5GB",   max = "5GB" }
      kali    = { min = "15GB",  max = "25GB" }
      windows = { min = "15GB",  max = "25GB" }
    }
    luks_encrypted = {
      nix_store  = { min = "25GB", max = "40GB" }
      home_diego = { min = "15GB", max = "40GB" }
      home_guest = { min = "5GB",  max = "10GB" }
      shared     = { min = "30GB", max = "50GB" }
    }
    total = {
      min = "~112GB"
      max = "~197GB"
      free = "~59-144GB headroom on 256GB drive"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUTS — Summary
# ═══════════════════════════════════════════════════════════════════════════════

output "device" {
  value = "${var.device} — ${local.hardware.cpu.model}, ${local.hardware.ram.size_gb}GB RAM, ${local.hardware.storage.size_gb}GB NVMe"
}

output "os_count" {
  value = "6 installed (NixOS, Kubuntu, Arch, Kali, Windows, Alpine) + 4 USB recovery images"
}

output "partitions" {
  value = "6 partitions: EFI + /boot + Alpine + Kali + Windows + LUKS (BTRFS pool)"
}

output "sessions" {
  value = "7 SDDM sessions: Plasma, GNOME, Android, Chrome Kiosk, Tor Kiosk, Openbox, GNOME Kiosk"
}

output "containers" {
  value = "2 Podman containers: cli-dev (Fedora 41, full dev stack) + gui-apps (Fedora 41, Flatpak GUI)"
}

output "home_manager" {
  value = "2 flakes: desktop (NixOS/Linux) + termux (Android)"
}

output "network" {
  value = "Firewall: TCP 22 only, default DROP. WireGuard: 10.0.0.5/24 (on-demand). SSH: password+pubkey, no root."
}
