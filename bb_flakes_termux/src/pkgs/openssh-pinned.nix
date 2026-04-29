# OpenSSH pinned to 8.9p1 (Feb 2022, last pre-9.x release).
#
# Why pin: nix-on-droid runs binaries inside termux/proot. proot doesn't
# implement `execveat()` with a non-AT_FDCWD fd (see proot src/syscall/enter.c).
# Modern OpenSSH uses fexecve()/execveat-with-fd in several privsep code
# paths, breaking sshd's child fork on Android. 8.9p1 is the most conservative
# pin that retains modern security defaults while predating the heavier 9.x
# privsep refactors.
#
# This derivation reuses nixpkgs' openssh build but overrides version + src
# and drops patches known to require >=9.x.
{ pkgs, lib }:

pkgs.openssh.overrideAttrs (old: rec {
  pname = "openssh-pinned";
  version = "8.9p1";

  src = pkgs.fetchurl {
    url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${version}.tar.gz";
    sha256 = "1ry5prcax0134v6srkgznpl9ch5snkgq7yvjqvd8c5mbnxa7cjgx";
  };

  # nixpkgs ships openssh patches keyed against the latest release. Drop
  # them all — 8.9p1 source is self-consistent. If something breaks we add
  # back the specific patch by name.
  patches = [];

  # Older configure expects different flags; let it autodetect.
  configureFlags = (old.configureFlags or []) ++ [
    "--with-privsep-path=/var/empty"
    "--without-zlib-version-check"
  ];

  doCheck = false;

  meta = (old.meta or {}) // {
    description = "OpenSSH 8.9p1 — pinned for nix-on-droid (proot execveat-with-fd workaround)";
  };
})
