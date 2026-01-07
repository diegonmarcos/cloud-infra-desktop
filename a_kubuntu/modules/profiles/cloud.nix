# Cloud profile - Cloud CLIs and DevOps tools
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
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

    # Docker/Containers
    docker-compose
    dive             # Docker image analyzer

    # Service mesh
    istioctl

    # Monitoring
    prometheus
    grafana

    # CI/CD
    gh               # GitHub CLI
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
