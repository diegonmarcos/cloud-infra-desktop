# syntax=docker/dockerfile:1.7
# Values come from install.json via build.sh --build-arg.
ARG BASE_IMAGE=kalilinux/kali-rolling:latest
FROM ${BASE_IMAGE}

ARG USER_NAME=kali
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_SHELL=/usr/bin/zsh
ARG TZ=Etc/UTC
ARG LANG_=en_US.UTF-8

# Whitespace-separated package lists, joined by build.sh from install.json.
ARG APT_BASE=""
ARG APT_GUI=""
ARG APT_META=""
ARG APT_RUNTIME=""

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=${LANG_} \
    LC_ALL=${LANG_}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1) Base packages first (small, cached well).
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

# 3) Kali metapackage (FULL TOOLS — kali-linux-everything ~ very large).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_META} \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# 4) Runtime helpers — small layer added AFTER the metapackage so future
#    additions (jq, etc.) do not invalidate the multi-GB layer above.
RUN if [ -n "${APT_RUNTIME}" ]; then \
        apt-get update \
     && apt-get install -y --no-install-recommends ${APT_RUNTIME} \
     && apt-get clean \
     && rm -rf /var/lib/apt/lists/* ; \
    fi

# Non-root user.
RUN groupadd -g ${USER_GID} ${USER_NAME} \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s ${USER_SHELL} ${USER_NAME} \
 && usermod -aG sudo,audio,video,plugdev,netdev ${USER_NAME} \
 && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} \
 && chmod 0440 /etc/sudoers.d/${USER_NAME}

# noVNC: provide /usr/share/novnc/index.html → vnc.html.
RUN if [ -d /usr/share/novnc ] && [ ! -e /usr/share/novnc/index.html ]; then \
      ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html; \
    fi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cli"]
