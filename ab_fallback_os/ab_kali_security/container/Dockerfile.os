# syntax=docker/dockerfile:1.7
# STAGE 1 — bootable minimum Kali OS.
# Output: kali-os:latest
# Pushed independently to GHCR as ghcr.io/diegonmarcos/kali-os:{latest,minimum}.
#
# What's here:
#   - kalilinux/kali-rolling base
#   - APT_BASE (sudo, curl, git, vim, tmux, zsh, locales, tzdata, etc.) ~270 MB
#   - APT_RUNTIME (jq for entrypoint config parsing) ~13 MB
#   - kali user + sudoers
#   - entrypoint.sh (dispatches cli / gui / scan modes)
#
# What's NOT here (lives in kali-lib FROM kali-os):
#   - APT_GUI (xfce4, tigervnc, novnc, …)
#   - APT_META (kali-linux-everything ~ 33 GB)
#
# Total: ~400 MB. Bootable with `cli` mode (interactive shell).
# `gui` and scanner modes require kali-lib.
ARG BASE_IMAGE=kalilinux/kali-rolling:latest
FROM ${BASE_IMAGE}

ARG TZ=Etc/UTC
ARG LANG_=en_US.UTF-8
ARG APT_BASE=""
ARG APT_RUNTIME=""
ARG USER_NAME=kali
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_SHELL=/usr/bin/zsh

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=${LANG_} \
    LC_ALL=${LANG_}

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/unix" \
      org.opencontainers.image.description="Kali Linux — bootable minimum OS (no pentest tools, no GUI). Pair with kali-lib for full toolset." \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.title="kali-os" \
      org.opencontainers.image.documentation="https://github.com/diegonmarcos/unix/tree/main/ab_fallback_os/ab_kali_security/container"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1) Base packages + locales + tz.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_BASE} \
 && sed -i "s/^# *${LANG_}/${LANG_}/" /etc/locale.gen \
 && locale-gen \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && rm -rf /var/lib/apt/lists/*

# 2) Runtime helpers (jq for entrypoint config parsing).
RUN if [ -n "${APT_RUNTIME}" ]; then \
        apt-get update \
     && apt-get install -y --no-install-recommends ${APT_RUNTIME} \
     && apt-get clean \
     && rm -rf /var/lib/apt/lists/* ; \
    fi

# 3) Non-root user.
RUN if ! getent group  ${USER_NAME} >/dev/null; then groupadd -g ${USER_GID} ${USER_NAME}; fi \
 && if ! id -u ${USER_NAME} >/dev/null 2>&1; then \
        useradd -m -u ${USER_UID} -g ${USER_GID} -s ${USER_SHELL} ${USER_NAME}; \
    fi \
 && usermod -aG sudo,audio,video,plugdev,netdev ${USER_NAME} \
 && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} \
 && chmod 0440 /etc/sudoers.d/${USER_NAME}

# 4) Entrypoint.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cli"]
