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
RUN apt-get install -y --no-install-recommends \
      waydroid \
      sway \
      seatd \
      wayvnc \
      dbus \
      pulseaudio \
      iproute2 \
      iptables \
      kmod \
      openssl \
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
RUN chmod +x /usr/local/bin/waydroid-container-entrypoint.sh

# XDG_RUNTIME_DIR set here (not just exported inside entrypoint.sh's own shell) so every
# `docker exec` — including `waydroid app install`/`waydroid app launch` run by the host —
# inherits it too. libdbus auto-discovers the session bus at $XDG_RUNTIME_DIR/bus (the D-Bus
# spec's well-known fallback path) with NO DBUS_SESSION_BUS_ADDRESS needed, as long as the
# session daemon is actually bound there (entrypoint.sh does this explicitly).
ENV XDG_RUNTIME_DIR=/tmp/xdg-runtime

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/waydroid-container-entrypoint.sh"]
