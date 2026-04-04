{
  "security": {
    "auth": {
      "selectedType": "oauth-personal"
    }
  },
  "general": {
    "previewFeatures": true
  },
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/tools/6-unix-mcp-api/src/index.ts"]
    },
    "cloud-infra": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "code-graph-context": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/index.ts"],
      "env": {
        "CONFIG_PATH": "/home/diego/git/cloud/config.json"
      }
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/index.ts"],
      "env": {
        "VAULT_PATH": "/home/diego/git/vault",
        "CONFIG_PATH": "/home/diego/git/cloud/config.json"
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
