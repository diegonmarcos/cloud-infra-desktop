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
    # terraform  # DISABLED: builds from source (~30min)
    ansible
    # packer     # DISABLED: builds from source (~20min)

    # Cloud CLIs
    google-cloud-sdk
    awscli2
    azure-cli
    oci-cli
    cloudflared
    flarectl

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
    # vault      # DISABLED: builds from source (~20min)
    sops
    age
  ];
}
