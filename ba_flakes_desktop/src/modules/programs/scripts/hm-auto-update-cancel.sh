#!/usr/bin/env bash
# Generated from programs/hm-auto-update.nix — cancel an in-flight
# auto-switch. The switch is a detached `systemd-run --user` unit named
# hm-auto-switch; stopping it aborts the download/activation.
exec systemctl --user stop hm-auto-switch
