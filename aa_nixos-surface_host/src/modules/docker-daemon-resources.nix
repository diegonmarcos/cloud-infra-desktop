# Docker Daemon — resource limits (documentation only)
#
# Docker resource limits are NOT configured in daemon.json.
# They are managed by systemd drop-ins in system-protection modules,
# which have access to hardware specs and calculate limits dynamically.
#
# ┌─────────────────────────────────────────────────────────────────┐
# │ This file exists for organizational consistency across the      │
# │ docker-daemon module family. No active configuration here.      │
# └─────────────────────────────────────────────────────────────────┘
#
# === Cloud VMs (system-protection-resource-bouncer.nix) ===
#
#   Deployed to: /etc/systemd/system/docker.service.d/memory-cap.conf
#
#   MemoryMax       = RAM - 350MB (1GB VMs) to RAM - 1GB (24GB VMs)
#   MemoryHigh      = MemoryMax × 90%  (triggers kernel memory pressure)
#   OOMScoreAdjust  = 500              (high priority for OOM killer)
#   CPUQuota        = 80%              (in docker.service unit, container-control-init.nix)
#
# === Desktop NixOS (this machine) ===
#
#   No Docker-specific resource limits — desktop has sufficient RAM (16GB+).
#   earlyoom (configuration_system-protection.nix) protects against
#   runaway containers by killing the highest-OOM-score process.
#
{ config, pkgs, lib, ... }:

{
  # Intentionally empty — see comments above for where limits are enforced.
}
