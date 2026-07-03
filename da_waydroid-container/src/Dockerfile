# waydroid-container — official Waydroid (LineageOS-based vendor Android image) baked
# into a Debian image alongside a headless weston compositor (VNC backend). Waydroid has
# no official Docker image — this installs it exactly as docs.waydro.id/usage/install-on-desktops
# documents (repo.waydro.id keyring + apt repo), just inside a container instead of bare metal.
#
# Why: Waydroid's vendor Android image is memfd-based (no real /dev/ashmem needed) since
# 1.2.1+, unlike redroid's stock AOSP image — so Chromium-based apps that crash under redroid
# on this ashmem-less host should work here.
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

# 2) waydroid itself + a headless weston compositor (vnc-backend.so — confirmed present in
#    Debian's weston package) for Waydroid's Wayland surface to render into, exported over VNC
#    to the host (mirrors da_redroid's scrcpy-window pattern, different transport).
RUN apt-get install -y --no-install-recommends \
      waydroid \
      weston \
      dbus \
      iproute2 \
      iptables \
      kmod \
      openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
