# 📖 Specifications & Design Documents

This directory contains the foundational specifications, design principles, and implementation tracking for the UNIX+USB Fallback structure.

---

## 🗺️ Core Documents

| Document | Description |
| :--- | :--- |
| **[ARCHITECTURE.md](./ARCHITECTURE.md)** | **Start here.** High-level overview of the system design, boot flow, and security zones. |
| **[DISK_LAYOUT.md](./DISK_LAYOUT.md)** | Precise partition map, UUIDs, BTRFS subvolumes, and mount points. |
| **[ISOLATION_LAYERS.md](./ISOLATION_LAYERS.md)** | Technical breakdown of sandbox technologies (Nix, Podman, Flatpak, MicroVM). |
| **[PERSONAL_SPACE.md](./PERSONAL_SPACE.md)** | Organization of the `@user/home` subvolume and personal data hierarchy. |
| **[ROADMAP.md](./ROADMAP.md)** | Progress tracking, pending tasks, and future milestones. |
| **[TOOLS.md](./TOOLS.md)** | Curated lists of software for each environment (Minimal, Basic, and Full). |

---

## 🛠️ Design Principles

1.  **Declarative Everything**: If it's not in a config file, it's temporary.
2.  **Stateless Root**: The root filesystem is wiped on every boot to ensure consistency.
3.  **Encrypted by Default**: Sensitive data is protected by LUKS2 with USB keyfile unlock.
4.  **Fail-Safe Recovery**: Always ensure a path to recovery even if the primary OS or LUKS headers are damaged.

---

## 📁 Internal Structure

- `z_dotfiles_src/`: Raw templates and source files for system dotfiles before they are processed by Nix or Home Manager.

---
*Created for Surface Pro 8 - 2026*
