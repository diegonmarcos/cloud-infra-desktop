{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/tools/6-unix-mcp-api/src/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules"
      }
    },
    "dtk": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/tools/7-dtk-mcp/src/index.ts"],
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
    "cloud-infra-local": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/cloud/a_solutions/bc-obs_c3-infra-mcp/src/code/mcp/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "GIT_BASE": "/home/diego/git"
      }
    },
    "cloud-cgc-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-cgc-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-cgc-mcp-local": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/code/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "CONFIG_PATH": "/home/diego/git/cloud/config.json"
      }
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": ["/home/diego/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/index.ts"],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
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
    },
    "google-personal": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-personal/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    }
  }
}
