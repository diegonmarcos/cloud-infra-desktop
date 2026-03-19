// Custom script tools — wrappers around connect.sh (unified hub) and related bins
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../exec.js";

export function registerScriptTools(server: McpServer) {
  // ═══ CONNECT — Unified hub (~/git/tools/a-cloud-connect/connect.sh) ═══

  // ── connect: dashboard ──
  server.tool(
    "connect_status",
    "Show unified dashboard: HM, mesh, git, drives, sync, servers, security",
    {},
    async () => {
      const result = sh(`connect status 2>&1`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  // ── connect: JSON data dump ──
  server.tool(
    "connect_logs",
    "JSON dump of all connect data (mesh, git, drives, sync, servers, gauges)",
    {
      section: z.enum(["all", "mesh", "git", "drives", "sync", "servers", "services", "webservers", "home_manager", "security", "gauges", "alerts"])
        .optional().describe("Section to extract (default: all)"),
    },
    async ({ section }) => {
      const jqFilter = section && section !== "all" ? ` | jq '.${section}'` : "";
      const result = sh(`connect logs 2>&1${jqFilter}`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  // ── connect: mesh (WireGuard VPN, VM mounts, OCI lifecycle) ──
  server.tool(
    "connect_mesh_status",
    "Show WireGuard VPN mesh status (VMs, connectivity, peers)",
    {},
    async () => {
      const result = sh(`connect logs 2>&1 | jq '.mesh'`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  server.tool(
    "connect_mesh_control",
    "Control VPN mesh: VM mounts (SSHFS) and OCI Flex lifecycle",
    {
      action: z.enum([
        "mount-vm", "unmount-vm", "mount-all-vm", "unmount-all",
        "mount-phone", "unmount-phone",
        "flex-start", "flex-stop", "flex-reset", "flex-status",
      ]).describe("Mesh action"),
      target: z.string().optional().describe("VM or resource name (for mount-vm, unmount-vm, flex-*)"),
    },
    async ({ action, target }) => {
      const args = target ? `${action} ${target}` : action;
      const result = sh(`connect ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${args}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: git (multi-repo management) ──
  server.tool(
    "connect_git_sync",
    "Sync all git repos (commit + pull + push)",
    {
      action: z.enum(["sync", "pull", "push", "commit", "fetch", "fetch-status", "dirty", "git-refresh"])
        .optional().describe("Git action (default: sync)"),
    },
    async ({ action }) => {
      const cmd = action ?? "sync";
      const result = sh(`connect ${cmd} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${cmd}`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "connect_gacp",
    "Git add, commit, and push all repos (convenience wrapper)",
    {
      message: z.string().optional().describe("Commit message (default: auto-generated)"),
    },
    async ({ message }) => {
      const args = message ? `"${message}"` : "";
      const result = sh(`gacp ${args} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult("gacp", result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: drives (rclone FUSE mounts) ──
  server.tool(
    "connect_drives",
    "Control rclone cloud drive mounts (GDrive, etc)",
    {
      action: z.enum(["mount-drive", "unmount-drive", "mount-all-drives", "unmount-all-drives", "toggle-drives"])
        .describe("Drive action"),
      name: z.string().optional().describe("Drive name (for mount-drive, unmount-drive)"),
    },
    async ({ action, name }) => {
      const args = name ? `${action} ${name}` : action;
      const result = sh(`connect ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${args}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: sync (rclone sync/bisync rules) ──
  server.tool(
    "connect_sync",
    "Control rclone sync rules and background jobs",
    {
      action: z.enum(["sync-run", "sync-run-bg", "sync-list", "sync-status", "sync-jobs", "sync-kill", "sync-clear-jobs"])
        .describe("Sync action"),
    },
    async ({ action }) => {
      const result = sh(`connect ${action} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: data servers (WebDAV, SFTP, HTTP) ──
  server.tool(
    "connect_server",
    "Control data servers (WebDAV, SFTP, HTTP+Eruda, Unison)",
    {
      action: z.enum(["server-start", "server-stop", "server-restart", "server-mode", "server-status", "bisync"])
        .describe("Server action"),
    },
    async ({ action }) => {
      const result = sh(`connect ${action} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: dev server (front-end dev servers) ──
  server.tool(
    "connect_dev_server",
    "Control front-end dev servers (list/start/stop)",
    {
      action: z.enum(["list", "start", "stop", "status"]).describe("Server action"),
      project: z.string().optional().describe("Project name (for start/stop)"),
    },
    async ({ action, project }) => {
      const args = project ? `${action} ${project}` : action;
      const result = sh(`server ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`server ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: code-server ──
  server.tool(
    "connect_code_server",
    "Control code-server (local/lan/stop/log/status)",
    {
      action: z.enum(["local", "lan", "stop", "log", "status"]).optional()
        .describe("Action (default: status)"),
    },
    async ({ action }) => {
      const result = sh(`code ${action ?? ""} 2>&1`, { timeout: 15_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  // ── connect: home-manager ──
  server.tool(
    "connect_hm",
    "Home-manager build/switch for VM configs",
    {
      action: z.enum(["hm-build", "hm-switch"]).describe("HM action"),
    },
    async ({ action }) => {
      const result = sh(`connect ${action} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── connect: security ──
  server.tool(
    "connect_security",
    "Show security dashboard (firewalls, WireGuard peers, Caddy routes)",
    {},
    async () => {
      const result = sh(`connect logs 2>&1 | jq '.security'`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );
}
