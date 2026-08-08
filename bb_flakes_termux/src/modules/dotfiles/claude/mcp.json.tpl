{
  "_doc": "HTTP-ONLY by decree (2026-08-08): stdio/tsx servers are BANNED on the phone — each spawn transpiles TypeScript through proot-taxed IO and cost 30s+ of claude startup. Everything runs as an HTTP endpoint behind mcp.diegonmarcos.com instead. The removed stdio entries (unix, cloud-cgc-mcp-local, diego-personal-data) live in git history if ever needed on a desktop.",
  "mcpServers": {
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
