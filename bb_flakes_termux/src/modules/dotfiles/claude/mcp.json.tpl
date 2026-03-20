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
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-specs-docs": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/data/data/com.termux.nix/files/home/git/cloud/a_solutions/bc-obs_c3-specs-docs-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "CONFIG_PATH": "/data/data/com.termux.nix/files/home/git/cloud/config.json"
      }
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/data/data/com.termux.nix/files/home/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "VAULT_PATH": "/data/data/com.termux.nix/files/home/git/vault",
        "CONFIG_PATH": "/data/data/com.termux.nix/files/home/git/cloud/config.json"
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
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mattermost-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "mailu-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mailu-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "google-workspace": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-workspace/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    }
  }
}
