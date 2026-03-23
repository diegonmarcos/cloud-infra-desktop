#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerDriftTools } from "./tools/drift.js";
import { registerNixTools } from "./tools/nix.js";
import { registerSystemTools } from "./tools/system.js";
import { registerScriptTools } from "./tools/scripts.js";
import { registerGitTools } from "./tools/git.js";
import { registerShellTools } from "./tools/shell.js";
import { registerShellConfigTools } from "./tools/shell-config.js";
import { registerEmailTools } from "./tools/email.js";
import { startMcpHttpServer } from "./http.js";

import { PLATFORM } from "./paths.js";

// All logging to stderr (stdout = JSON-RPC in stdio mode)
const log = (msg: string) => process.stderr.write(`[unix-mcp] ${msg}\n`);

function createServer(): McpServer {
  const server = new McpServer({
    name: "unix-mcp",
    version: "1.3.0",
  });

  // ── Tool categories ─────────────────────────────
  registerDriftTools(server);       //  3: nix-drift (version drift detection)
  registerNixTools(server);         //  6: flake info, update, switch, search, store, generations
  registerSystemTools(server);      //  5: info, env, which, processes, packages
  registerScriptTools(server);      // 12: connect hub (status, logs, mesh, git, drives, sync, server, dev, code, hm, security)
  registerGitTools(server);         //  4: status-all, log, diff, remote-status
  registerShellTools(server);       //  3: exec, npm-list, npm-install
  registerShellConfigTools(server); //  7: aliases, functions, greeting, starship, guardrails
  registerEmailTools(server);       //  5: imap-fetch, imap-list, imap-raw, cert-check, smtp-test

  return server;
}

// ── Transport selection ─────────────────────────────
// --http or MCP_HTTP=1 → persistent HTTP server (no reconnect needed)
// default → stdio (standard MCP transport)
const useHttp = process.argv.includes("--http") || process.env.MCP_HTTP === "1";

async function main() {
  log(`Starting unix-mcp v1.3.0 (45 tools, platform=${PLATFORM})...`);

  if (useHttp) {
    const port = parseInt(process.env.MCP_HTTP_PORT ?? "3200", 10);
    await startMcpHttpServer(createServer, port);
    log(`HTTP transport on 127.0.0.1:${port}/mcp`);
  } else {
    const server = createServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
    log("Connected via stdio transport");
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
