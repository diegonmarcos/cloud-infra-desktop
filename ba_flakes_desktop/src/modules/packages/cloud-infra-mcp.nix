# cloud-infra MCP Server - Personal cloud infrastructure management
{ lib, buildNpmPackage, nodejs }:

buildNpmPackage rec {
  pname = "cloud-infra-mcp";
  version = "1.0.0";

  # Use local source from cloud repo (filtered to avoid unnecessary rebuilds)
  src = builtins.path {
    path = /home/diego/Mounts/Git/cloud/a_solutions/bb-sec_mcp-server-skills;
    name = "cloud-infra-mcp-src";
  };

  # Hash computed via: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  npmDepsHash = "sha256-MxaYQAzRBRbigHmGUUi/y3LIwK6eNhmRh3yyL8xYcCs=";

  # Build TypeScript to JavaScript
  npmBuildScript = "build";

  # The compiled output is the MCP server entrypoint
  # Node will find @modelcontextprotocol/sdk in node_modules bundled by Nix
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/cloud-infra-mcp

    # Copy built dist/ and node_modules
    cp -r dist $out/lib/cloud-infra-mcp/
    cp -r node_modules $out/lib/cloud-infra-mcp/
    cp package.json $out/lib/cloud-infra-mcp/

    # Create wrapper script
    cat > $out/bin/cloud-infra-mcp <<EOF
#!/bin/sh
exec ${nodejs}/bin/node $out/lib/cloud-infra-mcp/dist/index.js "\$@"
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
