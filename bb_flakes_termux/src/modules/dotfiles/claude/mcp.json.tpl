{
  "mcpServers": {
    "unix": {
      "type": "stdio",
      "command": "tsx",
      "args": [
        "--import",
        "/data/data/com.termux.nix/files/home/.node_modules/esm-loader-register.mjs",
        "/data/data/com.termux.nix/files/home/git/tools/products/mcp-unix-api/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules"
      },
      "alwaysLoad": false
    },
    "dtk": {
      "type": "stdio",
      "command": "tsx",
      "args": [
        "--import",
        "/data/data/com.termux.nix/files/home/.node_modules/esm-loader-register.mjs",
        "/data/data/com.termux.nix/files/home/git/tools/products/mcp-dtk/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules"
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
    "cloud-infra-local": {
      "type": "stdio",
      "command": "tsx",
      "args": [
        "--import",
        "/data/data/com.termux.nix/files/home/.node_modules/esm-loader-register.mjs",
        "/data/data/com.termux.nix/files/home/git/cloud/a_solutions/bc-obs_c3-infra-mcp/src/code/mcp/index.ts"
      ],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "GIT_BASE": "/data/data/com.termux.nix/files/home/git"
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
      "command": "tsx",
      "args": [
        "--import",
        "/data/data/com.termux.nix/files/home/.node_modules/esm-loader-register.mjs",
        "/data/data/com.termux.nix/files/home/git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/code/index.ts"
      ],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "CONFIG_PATH": "/data/data/com.termux.nix/files/home/git/cloud/config.json",
        "GIT_ROOT": "/data/data/com.termux.nix/files/home/git",
        "OCTOCODE_BIN": "/data/data/com.termux.nix/files/home/.nix-profile/bin/octocode"
      },
      "alwaysLoad": false
    },
    "diego-personal-data": {
      "type": "stdio",
      "command": "tsx",
      "args": [
        "--import",
        "/data/data/com.termux.nix/files/home/.node_modules/esm-loader-register.mjs",
        "/data/data/com.termux.nix/files/home/git/cloud/a_solutions/infra-api_c3-diego-personal-data-mcp/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/data/data/com.termux.nix/files/home/.node_modules/node_modules",
        "VAULT_PATH": "/data/data/com.termux.nix/files/home/git/vault",
        "CONFIG_PATH": "/data/data/com.termux.nix/files/home/git/cloud/config.json"
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
    "mattermost": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mattermost-mcp/mcp",
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
