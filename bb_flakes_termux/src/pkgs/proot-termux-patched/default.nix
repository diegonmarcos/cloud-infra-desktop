# proot-termux-patched
#
# A drop-in replacement for nix-on-droid's bundled proot-termux that adds
# support for execveat() with a non-AT_FDCWD file descriptor (the
# fexecve / AT_EMPTY_PATH pattern used by OpenSSH 9.x privsep re-exec,
# modern dropbear, and apk-tools v3).
#
# Without this patch, those binaries die with -ENOSYS on every child
# process spawn under nix-on-droid's proot. See:
#   - termux/proot src/syscall/enter.c:138 (the bail line)
#   - termux/proot-distro#595
#
# The build mirrors nix-on-droid/pkgs/proot-termux/default.nix exactly,
# only adding our patch + a `detranslate-empty.patch` placeholder fetched
# from upstream (kept identical so behavior is unchanged for all other
# syscalls).
#
# Args mirror nix-on-droid's own derivation so we can drop this in via a
# pkgs override / overlay.

{ stdenv
, fetchFromGitHub
, fetchurl
, talloc
, static ? true
, outputBinaryName ? "proot-static"
}:

stdenv.mkDerivation {
  pname = "proot-termux-patched";
  version = "unstable-2024-05-04+execveat-fd";

  src = fetchFromGitHub {
    repo = "proot";
    owner = "termux";
    rev = "60485d2646c1e09105099772da4a20deda8d020d";
    sha256 = "sha256-zHFPiL3ywZa8yzZa600BpoE+zuRipw2GNJrt3/Dy+/E=";
  };

  preConfigure = ''
    mkdir -p fake-ashmem/linux; cat > fake-ashmem/linux/ashmem.h << EOF
    #include <linux/limits.h>
    #include <linux/ioctl.h>
    #include <string.h>
    #define __ASHMEMIOC 0x77
    #define ASHMEM_NAME_LEN 256
    #define ASHMEM_SET_NAME _IOW(__ASHMEMIOC, 1, char[ASHMEM_NAME_LEN])
    #define ASHMEM_SET_SIZE _IOW(__ASHMEMIOC, 3, size_t)
    #define ASHMEM_GET_SIZE _IO(__ASHMEMIOC, 4)
    EOF
    substituteInPlace src/arch.h --replace \
      '#define HAS_LOADER_32BIT true' \
      ""
    ! (grep -F '#define HAS_LOADER_32BIT' src/arch.h)
  '';

  buildInputs = [ talloc ];

  # Upstream patch (detranslate-empty.patch) lives in nix-on-droid's tree.
  # We re-fetch it from the nix-on-droid repo so this derivation is
  # self-contained — no need to import the entire nix-on-droid source.
  patches = [
    (fetchurl {
      url = "https://raw.githubusercontent.com/nix-community/nix-on-droid/release-24.05/pkgs/proot-termux/detranslate-empty.patch";
      sha256 = "1v5aknlc84d8glngsw0idd16p821ygmcd841sd0qv69gs6nh8qmf";
    })
    ./execveat-with-fd.patch
  ];

  makeFlags = [ "-Csrc" "V=1" ];
  CFLAGS = [ "-O3" "-I../fake-ashmem" ] ++
    (if static then [ "-static" ] else [ ]);
  LDFLAGS = if static then [ "-static" ] else [ ];
  preInstall = "${stdenv.cc.targetPrefix}strip src/proot";
  installPhase = "install -D -m 0755 src/proot $out/bin/${outputBinaryName}";
}
