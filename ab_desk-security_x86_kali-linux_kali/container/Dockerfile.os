# syntax=docker/dockerfile:1.7
# kali-os — single bootable Kali image (OS + libs + tools + GUI).
# Output: kali-os:latest  → ghcr.io/diegonmarcos/kali-os:{latest,full}
#
# Carries everything system-baked (binaries, configs, system data) but
# OMITS the bulk standalone data sets (wordlists, seclists, exploitdb,
# docs/man) — those live in kali-data and are bind-mounted at runtime
# under /usr/share/{wordlists,seclists,exploitdb}.
#
# The data dirs are deleted in the SAME RUN step that installs them so
# they don't survive in any layer (saves ~6 GB).
ARG BASE_IMAGE=kalilinux/kali-rolling:latest
FROM ${BASE_IMAGE}

ARG TZ=Etc/UTC
ARG LANG_=en_US.UTF-8
ARG APT_BASE=""
ARG APT_GUI=""
ARG APT_META=""
ARG APT_RUNTIME=""
ARG USER_NAME=kali
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_SHELL=/usr/bin/zsh

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=${LANG_} \
    LC_ALL=${LANG_}

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra-desktop" \
      org.opencontainers.image.description="Kali Linux — full toolkit + GUI. Bind-mount kali-data for wordlists/exploitdb/seclists." \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.title="kali-os" \
      org.opencontainers.image.documentation="https://github.com/diegonmarcos/cloud-infra-desktop/tree/main/ab_fallback_os/ab_kali_security/container"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1) Base packages + locales + tz.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_BASE} \
 && sed -i "s/^# *${LANG_}/${LANG_}/" /etc/locale.gen \
 && locale-gen \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && rm -rf /var/lib/apt/lists/*

# 2) GUI stack (XFCE + VNC + noVNC).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_GUI} \
 && rm -rf /var/lib/apt/lists/*

# 3) Kali metapackage (kali-linux-everything ~33 GB) — install AND remove
#    the bulk data dirs in the same RUN step so they don't survive in the
#    layer. The packages stay installed (dpkg-wise), only their bulk
#    /usr/share/{wordlists,seclists,exploitdb,doc,man} payload is purged.
#    Tools that need this data get it via the kali-data bind mount.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_META} \
 && rm -rf /usr/share/wordlists \
           /usr/share/seclists \
           /usr/share/exploitdb \
           /usr/share/doc \
           /usr/share/man \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# 4) Runtime helpers (jq for entrypoint config parsing).
RUN if [ -n "${APT_RUNTIME}" ]; then \
        apt-get update \
     && apt-get install -y --no-install-recommends ${APT_RUNTIME} \
     && apt-get clean \
     && rm -rf /var/lib/apt/lists/* ; \
    fi

# 5) Non-root user.
RUN if ! getent group  ${USER_NAME} >/dev/null; then groupadd -g ${USER_GID} ${USER_NAME}; fi \
 && if ! id -u ${USER_NAME} >/dev/null 2>&1; then \
        useradd -m -u ${USER_UID} -g ${USER_GID} -s ${USER_SHELL} ${USER_NAME}; \
    fi \
 && usermod -aG sudo,audio,video,plugdev,netdev ${USER_NAME} \
 && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} \
 && chmod 0440 /etc/sudoers.d/${USER_NAME}

# 6) noVNC index alias.
RUN if [ -d /usr/share/novnc ] && [ ! -e /usr/share/novnc/index.html ]; then \
      ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html; \
    fi

# 7) Entrypoint.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cli"]
