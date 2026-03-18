{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/unix/bc_unix-mcp-api/src/index.ts"]
    },
    "cloud-infra": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-specs-docs": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/cloud/a_solutions/bc-obs_c3-specs-docs-mcp/src/index.ts"],
      "env": {
        "CONFIG_PATH": "/home/diego/Mounts/Git/cloud/config.json"
      }
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/Mounts/Git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/index.ts"],
      "env": {
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
    "mailu-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mailu-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "google-workspace": {
      "type": "http",
      "url": "http://10.0.0.6:3104/mcp"
    }
  }
}
