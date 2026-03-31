#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# install.sh — reads deps.json, installs everything
# Usage: ./install.sh <layer>
# Layers: apt, rust, go, node, pip, ruby, java, cloud, nix, cuda, android, repos, fish, verify
# ══════════════════════════════════════════════════════════════
set -euo pipefail

DEPS="/etc/forge/deps.json"
ARCH=$(dpkg --print-architecture)  # amd64 or arm64

# ── helpers ──────────────────────────────────────────────────
jq_arr()  { jq -r "$1 // [] | .[]" "$DEPS" 2>/dev/null; }
jq_val()  { jq -r "$1 // empty" "$DEPS" 2>/dev/null; }
jq_flat() { jq -r "[$1] | flatten | .[]" "$DEPS" 2>/dev/null; }

latest_gh_version() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name' | tr -d v
}

case "${1:-all}" in

apt)
  echo "=== APT packages ==="
  PKGS=$(jq -r '.apt | to_entries[] | .value[]' "$DEPS" | sort -u | tr '\n' ' ')
  apt-get update && apt-get install -y $PKGS
  locale-gen en_US.UTF-8
  rm -rf /var/lib/apt/lists/*
  ;;

rust)
  echo "=== Rust ==="
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "$(jq_val '.rust.channel')"
  . ~/.cargo/env
  for tc in $(jq_arr '.rust.extra_toolchains'); do rustup toolchain install "$tc"; done
  for comp in $(jq_arr '.rust.components'); do rustup component add "$comp"; done
  for tool in $(jq_arr '.rust.cargo_tools'); do cargo install "$tool" 2>/dev/null || true; done
  for tool in $(jq_arr '.rust.cargo_terminal'); do cargo install "$tool" 2>/dev/null || true; done
  rustc --version && cargo --version
  ;;

go)
  echo "=== Go ==="
  GOVERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -1)
  curl -sL "https://go.dev/dl/${GOVERSION}.linux-${ARCH}.tar.gz" | tar xz -C /usr/local
  for tool in $(jq_arr '.go.tools'); do go install "$tool"; done
  go version
  ;;

node)
  echo "=== Node.js ==="
  NODE_VER=$(jq_val '.node.version')
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VER}.x" | bash -
  apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*
  PKGS=$(jq_arr '.node.global' | tr '\n' ' ')
  npm install -g $PKGS
  node --version && npm --version
  ;;

pip)
  echo "=== Python pip ==="
  PKGS=$(jq -r '.pip | to_entries[] | .value[]' "$DEPS" | sort -u | tr '\n' ' ')
  python3 -m pip install --break-system-packages $PKGS
  python3 --version
  ;;

ruby)
  echo "=== Ruby gems ==="
  for gem in $(jq_arr '.ruby_gems'); do gem install "$gem" 2>/dev/null || true; done
  ruby --version
  ;;

r)
  echo "=== R packages ==="
  R_PKGS=$(jq_arr '.r_packages' | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')
  R -e "install.packages(c($R_PKGS), repos='https://cloud.r-project.org')"
  ;;

cloud)
  echo "=== Cloud CLIs ==="
  # Docker
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
  apt-get update && apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && rm -rf /var/lib/apt/lists/*
  # kubectl
  KUBE_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sL "https://dl.k8s.io/release/${KUBE_VER}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl
  # helm
  curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  # terraform
  TF_VER=$(curl -sL https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r '.current_version')
  curl -sL "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_${ARCH}.zip" -o /tmp/tf.zip
  unzip /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip
  # gh
  GH_VER=$(latest_gh_version "cli/cli")
  curl -sL "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${ARCH}.tar.gz" | tar xz --strip-components=1 -C /usr/local
  # sops
  SOPS_VER=$(latest_gh_version "getsops/sops")
  curl -sL "https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.${ARCH}" -o /usr/local/bin/sops && chmod +x /usr/local/bin/sops
  # age
  AGE_VER=$(latest_gh_version "FiloSottile/age")
  curl -sL "https://github.com/FiloSottile/age/releases/download/v${AGE_VER}/age-v${AGE_VER}-linux-${ARCH}.tar.gz" | tar xz --strip-components=1 -C /usr/local/bin
  # starship
  curl -sS https://starship.rs/install.sh | sh -s -- -y
  # duf
  DUF_VER=$(latest_gh_version "muesli/duf")
  curl -sL "https://github.com/muesli/duf/releases/download/v${DUF_VER}/duf_${DUF_VER}_linux_${ARCH}.deb" -o /tmp/duf.deb && dpkg -i /tmp/duf.deb && rm /tmp/duf.deb
  # act
  ACT_VER=$(latest_gh_version "nektos/act")
  curl -sL "https://github.com/nektos/act/releases/download/v${ACT_VER}/act_Linux_x86_64.tar.gz" | tar xz -C /usr/local/bin act
  ;;

nix)
  echo "=== Nix ==="
  groupadd -r nixbld 2>/dev/null || true
  for i in $(seq 1 10); do useradd -r -g nixbld -G nixbld -d /var/empty -s /sbin/nologin "nixbld$i" 2>/dev/null || true; done
  curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
  . /root/.nix-profile/etc/profile.d/nix.sh
  mkdir -p /root/.config/nix
  echo "experimental-features = nix-command flakes" > /root/.config/nix/nix.conf
  nix --version
  ;;

cuda)
  echo "=== CUDA ==="
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
  dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb
  PKGS=$(jq_arr '.cuda.packages' | tr '\n' ' ')
  apt-get update && apt-get install -y --no-install-recommends $PKGS && rm -rf /var/lib/apt/lists/*
  ;;

android)
  echo "=== Android SDK + Kotlin ==="
  mkdir -p /opt/android-sdk/cmdline-tools
  curl -sL "$(jq_val '.android.cmdline_tools')" -o /tmp/cmdline-tools.zip
  unzip -q /tmp/cmdline-tools.zip -d /opt/android-sdk/cmdline-tools
  mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest
  rm /tmp/cmdline-tools.zip
  yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses 2>/dev/null || true
  for pkg in $(jq_arr '.android.sdk_packages'); do
    /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager "$pkg" 2>/dev/null || true
  done
  # Kotlin
  KOTLIN_VER=$(curl -sL https://api.github.com/repos/JetBrains/kotlin/releases/latest | jq -r '.tag_name' | tr -d v)
  curl -sL "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VER}/kotlin-compiler-${KOTLIN_VER}.zip" -o /tmp/kotlin.zip
  unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip
  ln -sf /opt/kotlinc/bin/kotlin /usr/local/bin/kotlin
  ln -sf /opt/kotlinc/bin/kotlinc /usr/local/bin/kotlinc
  ;;

repos)
  echo "=== Repos ==="
  mkdir -p /repos
  for entry in $(jq -r '.repos | to_entries[] | "\(.key):\(.value)"' "$DEPS"); do
    DIR=$(echo "$entry" | cut -d: -f1)
    REMOTE=$(echo "$entry" | cut -d: -f2)
    echo "Cloning $DIR from $REMOTE"
    git clone --depth 1 "https://github.com/${REMOTE}.git" "/repos/${DIR}" 2>/dev/null || true
  done
  ;;

fish)
  echo "=== Fish config ==="
  mkdir -p /root/.config/fish/functions /root/.config/fish/conf.d
  chsh -s /usr/bin/fish root 2>/dev/null || true
  # Fisher + starship handled by Dockerfile COPY of config files
  ;;

verify)
  echo "=== Generating deps inventory ==="
  # Export installed versions to deps-installed.json
  jq -n \
    --arg gcc "$(gcc --version 2>/dev/null | head -1)" \
    --arg clang "$(clang --version 2>/dev/null | head -1)" \
    --arg rust "$(rustc --version 2>/dev/null)" \
    --arg go "$(go version 2>/dev/null)" \
    --arg node "$(node --version 2>/dev/null)" \
    --arg python "$(python3 --version 2>/dev/null)" \
    --arg ruby "$(ruby --version 2>/dev/null | cut -d' ' -f1-2)" \
    --arg java "$(java --version 2>&1 | head -1)" \
    --arg docker "$(docker --version 2>/dev/null)" \
    --arg nix "$(nix --version 2>/dev/null)" \
    --arg terraform "$(terraform --version 2>/dev/null | head -1)" \
    --arg kubectl "$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')" \
    --arg helm "$(helm version --short 2>/dev/null)" \
    --arg gh "$(gh --version 2>/dev/null | head -1)" \
    --arg sops "$(sops --version 2>/dev/null)" \
    --arg starship "$(starship --version 2>/dev/null)" \
    --arg octocode "$(octocode --version 2>/dev/null)" \
    --arg arch "$(uname -m)" \
    --arg date "$(date -Iseconds)" \
    --argjson deb_count "$(dpkg -l | tail -n+6 | wc -l)" \
    --argjson pip_count "$(pip list 2>/dev/null | wc -l)" \
    --argjson npm_count "$(npm list -g --depth=0 2>/dev/null | wc -l)" \
    '{
      _generated: $date, _arch: $arch,
      counts: {deb: $deb_count, pip: $pip_count, npm: $npm_count},
      versions: {gcc:$gcc, clang:$clang, rust:$rust, go:$go, node:$node, python:$python, ruby:$ruby, java:$java, docker:$docker, nix:$nix, terraform:$terraform, kubectl:$kubectl, helm:$helm, gh:$gh, sops:$sops, starship:$starship, octocode:$octocode}
    }' > /root/deps-installed.json
  echo "Wrote /root/deps-installed.json"
  cat /root/deps-installed.json
  ;;

all)
  for layer in apt rust go node pip ruby r cloud nix cuda android repos fish verify; do
    echo ""
    echo "████████████████████████████████████████"
    echo "  LAYER: $layer"
    echo "████████████████████████████████████████"
    $0 "$layer"
  done
  ;;

esac
