# Profile 4: Containers & Cloud
# DevOps, infrastructure, orchestration
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Container tools
    podman
    podman-compose
    buildah
    skopeo
    dive             # Docker image analyzer

    # Kubernetes
    kubectl
    kubernetes-helm
    k9s              # Kubernetes TUI
    kubectx
    stern            # Multi-pod log tailing

    # Infrastructure as Code
    terraform
    ansible
    packer

    # Cloud CLIs
    google-cloud-sdk
    awscli2
    azure-cli
    # Note: oci-cli installed via pipx (not in nixpkgs)

    # Docker Compose (for compatibility)
    docker-compose

    # Service mesh
    istioctl

    # Monitoring
    prometheus
    grafana

    # CI/CD
    gitlab-runner

    # Secrets management
    vault
    sops
    age
  ];

  # Install oci-cli via pipx (not available in nixpkgs)
  home.activation.installOciCli = lib.hm.dag.entryAfter ["writeBoundary"] ''
    if command -v pipx &>/dev/null; then
      $DRY_RUN_CMD pipx install oci-cli 2>/dev/null || true
    fi
  '';
}
