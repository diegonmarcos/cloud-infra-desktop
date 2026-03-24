# cloud-infra MCP Server - Personal cloud infrastructure management
{ lib, buildNpmPackage, nodejs }:

buildNpmPackage rec {
  pname = "cloud-infra-mcp";
  version = "1.0.0";

  # Use local source from cloud repo (filtered to avoid unnecessary rebuilds)
  src = builtins.path {
    path = /home/diego/Mounts/Git/cloud/a_solutions/bc-obs_c3-infra-mcp/src;
    name = "cloud-infra-mcp-src";
  };

  # Hash computed via: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  npmDepsHash = "sha256-OInQyAlRXxSVKJpi+2G7hCncKJHoUhDWNQPM3PT9iMM=";

  # Skip TS build — MCP server runs via npx tsx at runtime
  dontNpmBuild = true;

  # The compiled output is the MCP server entrypoint
  # Node will find @modelcontextprotocol/sdk in node_modules bundled by Nix
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/cloud-infra-mcp

    # Copy source + node_modules (runs via tsx, no compiled dist/)
    cp -r . $out/lib/cloud-infra-mcp/

    # Create wrapper script
    cat > $out/bin/cloud-infra-mcp <<EOF
#!/bin/sh
exec ${nodejs}/bin/npx tsx $out/lib/cloud-infra-mcp/index.ts "\$@"
EOF
    chmod +x $out/bin/cloud-infra-mcp

    runHook postInstall
  '';

  meta = with lib; {
    description = "MCP server for managing personal cloud infrastructure (4 VMs, 48 services)";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "cloud-infra-mcp";
  };
}
