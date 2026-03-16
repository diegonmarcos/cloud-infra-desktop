// Custom script tools — wrappers around the writeShellScriptBin tools from flakes
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { bash, formatResult } from "../exec.js";

export function registerScriptTools(server: McpServer) {
  // ── sync (git + rclone unified sync engine) ──
  server.tool(
    "sync_status",
    "Show sync status for all git repos and rclone mounts",
    {},
    async () => {
      const result = bash(`sync status 2>&1`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  server.tool(
    "sync_git",
    "Sync git repos (pull/push)",
    {
      mode: z.enum(["local", "remote"]).optional().describe("local=pull only, remote=pull+push (default: local)"),
    },
    async ({ mode }) => {
      const result = bash(`sync git ${mode ?? "local"} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult("sync git", result) }],
        isError: !result.ok,
      };
    }
  );

  // ── gacp (Git Add, Commit, Push) ──
  server.tool(
    "gacp",
    "Git add, commit, and push all repos via sync engine",
    {
      message: z.string().optional().describe("Commit message (default: auto-generated)"),
    },
    async ({ message }) => {
      const args = message ? `"${message}"` : "";
      const result = bash(`gacp ${args} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult("gacp", result) }],
        isError: !result.ok,
      };
    }
  );

  // ── mesh (WireGuard VPN management) ──
  server.tool(
    "mesh_status",
    "Show WireGuard VPN mesh status (tunnel connectivity, peers)",
    {},
    async () => {
      const result = bash(`mesh status 2>&1`, { timeout: 15_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  server.tool(
    "mesh_control",
    "Control WireGuard VPN tunnel (up/down/peers)",
    {
      action: z.enum(["up", "down", "peers"]).describe("VPN action"),
    },
    async ({ action }) => {
      const result = bash(`mesh ${action} 2>&1`, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`mesh ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect (unified dashboard) ──
  server.tool(
    "connect_status",
    "Show unified dashboard: git repos, mounts, sync, servers status",
    {},
    async () => {
      const result = bash(`connect status 2>&1`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  // ── server (dev server control) ──
  server.tool(
    "dev_server",
    "Control front-end dev servers (list/start/stop)",
    {
      action: z.enum(["list", "start", "stop", "status"]).describe("Server action"),
      project: z.string().optional().describe("Project name (for start/stop)"),
    },
    async ({ action, project }) => {
      const args = project ? `${action} ${project}` : action;
      const result = bash(`server ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`server ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── code (code-server) ──
  server.tool(
    "code_server",
    "Control code-server (local/lan/stop/log/status)",
    {
      action: z.enum(["local", "lan", "stop", "log", "status"]).optional()
        .describe("Action (default: status)"),
    },
    async ({ action }) => {
      const result = bash(`code ${action ?? ""} 2>&1`, { timeout: 15_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );
}
