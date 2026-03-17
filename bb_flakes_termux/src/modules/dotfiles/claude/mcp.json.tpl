{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/data/data/com.termux.nix/files/home/git/unix/bc_unix-mcp-api/src/index.ts"],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules"
      }
    },
    "cloud-infra": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-services": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-services-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "mattermost": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/data/data/com.termux.nix/files/home/git/cloud/a_solutions/aa-sui_mattermost-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "MM_URL": "https://chat.diegonmarcos.com",
        "MM_CLAUDE_PASSWORD": "${MM_CLAUDE_PASSWORD}",
        "MM_TEAM_ID": "x89hszqz97g6dxytbtx3p5mmkc",
        "MM_ADMIN_USERNAME": "me@diegonmarcos.com",
        "CLAUDE_MODEL": "opus"
      }
    },
    "mailu-mcp": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/data/data/com.termux.nix/files/home/git/cloud/a_solutions/aa-sui_mailu-mcp/src/mcp/index.ts"],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "MAIL_USER": "${MAILU_USER}",
        "MAIL_PASSWORD": "${MAILU_PASSWORD}"
      }
    }
  }
}
