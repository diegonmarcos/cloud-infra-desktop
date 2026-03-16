#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerDriftTools } from "./tools/drift.js";
import { registerNixTools } from "./tools/nix.js";
import { registerSystemTools } from "./tools/system.js";
import { registerScriptTools } from "./tools/scripts.js";
import { registerGitTools } from "./tools/git.js";
import { registerShellTools } from "./tools/shell.js";

import { PLATFORM } from "./paths.js";

const server = new McpServer({
  name: "unix-mcp",
  version: "1.0.0",
});

// ── Tool categories ─────────────────────────────
registerDriftTools(server);   //  3: nix-drift (version drift detection)
registerNixTools(server);     //  6: flake info, update, switch, search, store, generations
registerSystemTools(server);  //  5: info, env, which, processes, packages
registerScriptTools(server);  //  8: sync, gacp, mesh, connect, server, code
registerGitTools(server);     //  4: status-all, log, diff, remote-status
registerShellTools(server);   //  3: exec, npm-list, npm-install

// All logging to stderr (stdout = JSON-RPC)
const log = (msg: string) => process.stderr.write(`[unix-mcp] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log(`Starting unix-mcp v1.0.0 (29 tools, platform=${PLATFORM})...`);
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
