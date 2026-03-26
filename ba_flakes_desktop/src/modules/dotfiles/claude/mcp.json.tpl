{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/unix/bc_unix-mcp-api/src/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules"
      }
    },
    "cloud-infra": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-cgc-mcp": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "CONFIG_PATH": "/home/diego/Mounts/Git/cloud/config.json",
        "OCTOCODE_BIN": "/home/diego/.local/bin/octocode"
      }
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "VAULT_PATH": "/home/diego/Mounts/Git/vault",
        "CONFIG_PATH": "/home/diego/Mounts/Git/cloud/config.json"
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
    "mail-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mail-mcp/mcp",
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
