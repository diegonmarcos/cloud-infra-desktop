{ lib
, stdenv
, fetchFromGitHub
, cmake
}:

stdenv.mkDerivation rec {
  pname = "termux-api";
  version = "0.59.0";

  src = fetchFromGitHub {
    owner = "termux";
    repo = "termux-api-package";
    rev = "v${version}";
    hash = "sha256-buDK6MKE3DdA/Kv0W4H1dgU69mQt15Wr05ETS4gaA70=";
  };

  nativeBuildInputs = [ cmake ];

  # Let CMake handle @TERMUX_PREFIX@ substitution in .in files
  cmakeFlags = [
    "-DTERMUX_PREFIX=${placeholder "out"}"
  ];

  # CMake install phase handles everything
  # Binary goes to libexec/termux-api
  # Scripts go to bin/termux-*

  meta = with lib; {
    description = "Termux API commands for accessing Android functionality";
    homepage = "https://github.com/termux/termux-api-package";
    license = licenses.asl20;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
