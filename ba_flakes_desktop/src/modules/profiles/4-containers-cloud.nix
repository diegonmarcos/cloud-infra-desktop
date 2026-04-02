# Profile 4: Containers & Cloud
# DevOps, infrastructure, orchestration
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Container tools
    docker-client
    podman
    youki            # Rust OCI runtime — replaces runc (Go)
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
    # packer     # DISABLED: builds from source (~20min)

    # Cloud CLIs
    google-cloud-sdk
    awscli2
    azure-cli
    oci-cli
    cloudflared
    flarectl

    # Docker Compose
    docker-compose
    docker-buildx

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
