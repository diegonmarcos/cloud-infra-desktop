{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": [
        "/home/diego/git/cloud-mykonsole-dtk/products/mcp-unix-api/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules"
      },
      "alwaysLoad": false
    },
    "cloud-infra": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-cgc-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-cgc-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-cgc-mcp-local": {
      "type": "stdio",
      "command": "/home/diego/.claude/mcp-local-launch.sh",
      "args": [
        "/home/diego/git/cloud-infra/a_solutions/user-ai_cloud-cgc-mcp/src/code/index.ts"
      ],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "CONFIG_PATH": "/home/diego/git/cloud-infra/config.json",
        "GIT_ROOT": "/home/diego/git"
      },
      "alwaysLoad": false
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "/home/diego/.claude/mcp-local-launch.sh",
      "args": [
        "/home/diego/git/cloud-infra/a_solutions/infra-api_c3-diego-personal-data-mcp/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "VAULT_PATH": "/home/diego/git/cloud-vault",
        "CONFIG_PATH": "/home/diego/git/cloud-infra/config.json"
      },
      "alwaysLoad": false
    },
    "cloud-services": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-services-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "mail-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mail-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "google-workspace": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-workspace/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "google-personal": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-personal/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    }
  }
}
