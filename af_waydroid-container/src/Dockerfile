# waydroid-container — official Waydroid (LineageOS-based vendor Android image) baked
# into a Debian image alongside a headless sway (wlroots) compositor exported over VNC
# via wayvnc. Waydroid has no official Docker image — this installs it exactly as
# docs.waydro.id/usage/install-on-desktops documents (repo.waydro.id keyring + apt repo),
# just inside a container instead of bare metal.
#
# sway+wayvnc, not weston+rdp-backend: Debian bookworm's weston 10.0.1 rdp-backend.so has
# a confirmed dead-connection bug (accepts the TCP handshake, never services the RDP
# protocol negotiation — isolated via fresh-container + single-client + thread-count +
# backtrace tests, 2026-07-04) and has no vnc-backend.so either. sway+wayvnc is the
# standard, actively-maintained combo for headless-Wayland VNC.
#
# Why: Waydroid's vendor Android image is memfd-based (no real /dev/ashmem needed) since
# 1.2.1+, unlike redroid's stock AOSP image — so Chromium-based apps that crash under redroid
# on this ashmem-less host (mainline kernel >=5.18 has no /dev/ashmem) should work here.
ARG BASE=debian:bookworm
FROM ${BASE}

# Exempts this image (and containers made from it) from the host's nightly
# `docker system prune -f --all --filter until=24h`, which deleted both the container
# and this 4GB image overnight on 2026-09-01 — docker never autostarts on that host and
# every container is restart=no, so at 00:00 nothing is running and everything looks
# unused. The matching `label!=cloud.preserve=true` filter lives in the NixOS module
# aa_desk-usr_x86_surface-linux_nixos/src/modules/docker-daemon.nix.
LABEL cloud.preserve=true

ENV DEBIAN_FRONTEND=noninteractive

# 1) Waydroid's own apt repo (exact steps from https://repo.waydro.id, UPSTREAM_CODENAME
#    pinned explicitly to bookworm for build reproducibility — no os-release sniffing).
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg \
    && curl --progress-bar --proto '=https' --tlsv1.2 -Sf https://repo.waydro.id/waydroid.gpg \
         --output /usr/share/keyrings/waydroid.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ bookworm main" \
         > /etc/apt/sources.list.d/waydroid.list \
    && apt-get update

# 2) waydroid itself + a headless sway compositor (wlroots, WLR_BACKENDS=headless — no
#    real GPU/input device touched) + wayvnc exporting it over VNC to the host (mirrors
#    da_redroid's scrcpy-window pattern, different transport). seatd: wlroots still
#    initializes libseat even in headless mode, so a minimal seat daemon must be running
#    (env vars alone are NOT sufficient). pulseaudio: Waydroid's LXC config mounts
#    $XDG_RUNTIME_DIR/pulse/native — hard mount failure without it.
#    grim: wlroots screenshot tool — used by `build.sh test` to capture what the
#    compositor ACTUALLY composites (the exact pixels wayvnc serves), so "it renders"
#    is verified evidence, never an assumption.
#    jq + sqlite3 + nodejs: app provisioning (entrypoint.sh reads build.json's
#    apps/launcher/theme with jq, applies the Launcher3 layout via sqlite3, and runs
#    gen-layout-sql.js — a small JS layout-SQL generator — via node).
RUN apt-get install -y --no-install-recommends \
      waydroid \
      git \
      sway \
      seatd \
      wayvnc \
      grim \
      dbus \
      pulseaudio \
      iproute2 \
      iptables \
      kmod \
      openssl \
      jq \
      sqlite3 \
      nodejs \
      zstd \
    && rm -rf /var/lib/apt/lists/*

# 2b) Sunshine — the PRIMARY display transport (VAAPI hardware H.264 encode of the sway
#     output, streamed to the host's Moonlight client — full GPU pipeline end-to-end).
#     Debian BOOKWORM builds ended at v2025.122.141614 (2026 releases ship trixie+ only),
#     so the .deb is pinned by URL + sha256 from build.json via build args (reproducible,
#     data-driven — never "latest"). intel-media-va-driver-non-free: the full iHD VAAPI
#     driver build with the encoders enabled (the free build ships decode-only for many
#     platforms) — requires the non-free component, enabled here for exactly this one
#     package. wayvnc (above) stays as the debug/fallback transport.
ARG SUNSHINE_DEB_URL
ARG SUNSHINE_DEB_SHA256
#     (the base image declares its sources in deb822 /etc/apt/sources.list.d/debian.sources
#     with Signed-By — a second plain-text list for the same origin CONFLICTS, so the
#     non-free components are added to the existing deb822 entry instead)
RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
      /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends intel-media-va-driver-non-free vainfo \
    && curl -fSL -o /tmp/sunshine.deb "$SUNSHINE_DEB_URL" \
    && echo "$SUNSHINE_DEB_SHA256  /tmp/sunshine.deb" | sha256sum -c - \
    && apt-get install -y --no-install-recommends /tmp/sunshine.deb \
    && rm -f /tmp/sunshine.deb \
    && rm -rf /var/lib/apt/lists/*

# 3) sway refuses to start as root ("Unable to drop root... refusing to start") — a
#    hard security check, not a flag-tunable option. The documented pattern for
#    headless sway in CI/Docker is a dedicated non-root user in the seatd-managed
#    group (matches `seatd -g video` in entrypoint.sh); root still owns D-Bus/
#    pulseaudio/waydroid and can freely open the sway user's Wayland socket (root
#    bypasses DAC permission checks — only sway's own startup check cares about EUID).
RUN useradd -m -G video sway-user

# 4) iptables-legacy vs nftables: this host's mainline kernel has no legacy xtables kernel
#    modules. waydroid-net.sh does `IPTABLES_BIN="$(command -v iptables-legacy)"` FIRST —
#    update-alternatives alone doesn't help since that command still resolves the legacy
#    binary. Remove it at IMAGE BUILD time (declarative, baked-in) so the script's own
#    `command -v` fallback picks the nftables-backed `iptables` binary instead.
RUN rm -f /usr/sbin/iptables-legacy /usr/sbin/ip6tables-legacy

# 5) xt_CHECKSUM kernel module is absent on modern mainline kernels (same class of gap as
#    ashmem) — waydroid-net.sh's DHCP checksum-fill rules fail with "Module xt_CHECKSUM not
#    found". Non-essential workaround for legacy kernels; sed it out at build time (baked
#    into the image, not a live runtime patch) rather than failing container boot.
RUN sed -i '/-j CHECKSUM --checksum-fill/d' /usr/lib/waydroid/data/scripts/waydroid-net.sh

COPY entrypoint.sh /usr/local/bin/waydroid-container-entrypoint.sh
COPY sway-waydroid.conf.tpl /etc/sway-waydroid.conf.tpl
COPY sunshine.conf.tpl /etc/sunshine.conf.tpl
COPY sunshine-apps.json /etc/sunshine-apps.json
# The self-contained host launcher (generated by `build.sh bundle` into the build
# context before `docker build`): build.json is baked into it, so it runs on any host
# with docker+bash+node and NO repo checkout. Shipped INSIDE the image so `build.sh
# install` can `docker cp` it out of the pulled GHCR image straight into ~/.local/bin.
COPY waydroid-launcher /opt/launcher/waydroid

# App provisioning: build.json (copied into the build context by `build.sh build`),
# the pinned APK set (fetched reproducibly by `build.sh apps-fetch` into src/apks/),
# and the Launcher3 layout-SQL generator. entrypoint.sh installs every APK, applies
# app-ops/permissions, renders the home-screen+nav layout, and sets the theme — ONCE
# per container lifetime, guarded by a marker on the persistent /var/lib/waydroid
# volume — the first time Android reaches boot_completed=1.
COPY build.json /etc/waydroid-container.json
COPY apks/ /opt/apps/
COPY apps/gen-layout-sql.js /opt/launcher/gen-layout-sql.js

# Baked /data seed — a full provisioned snapshot (vendor images + installed apps +
# seeded layout/theme) produced by `build.sh bake`. `build.sh build` writes an EMPTY
# placeholder here so this COPY always resolves; the entrypoint treats an empty seed
# as "not baked" and falls back to runtime provisioning. When `bake` fills it, first
# boot restores it and is instantly at the curated home screen. LAST COPY so a bake
# only rebuilds this one (multi-GB) layer, not the whole image.
COPY data-seed.tar.zst /opt/data-seed.tar.zst

RUN chmod +x /usr/local/bin/waydroid-container-entrypoint.sh /opt/launcher/waydroid

# XDG_RUNTIME_DIR set here (not just exported inside entrypoint.sh's own shell) so every
# `docker exec` — including `waydroid app install`/`waydroid app launch` run by the host —
# inherits it too. libdbus auto-discovers the session bus at $XDG_RUNTIME_DIR/bus (the D-Bus
# spec's well-known fallback path) with NO DBUS_SESSION_BUS_ADDRESS needed, as long as the
# session daemon is actually bound there (entrypoint.sh does this explicitly).
ENV XDG_RUNTIME_DIR=/tmp/xdg-runtime

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/waydroid-container-entrypoint.sh"]
