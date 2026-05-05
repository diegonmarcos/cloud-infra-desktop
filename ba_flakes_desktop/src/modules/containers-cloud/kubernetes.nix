# containers-cloud/kubernetes.nix — k8s clients, TUIs, service-mesh CLI
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s              # Kubernetes TUI
    kubectx
    stern            # multi-pod log tailing

    # Service mesh
    istioctl
  ];
}
