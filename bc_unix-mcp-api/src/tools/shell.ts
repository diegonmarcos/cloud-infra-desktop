// Shell tools — run arbitrary commands, npm, etc. (POSIX sh)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../exec.js";

export function registerShellTools(server: McpServer) {
  server.tool(
    "shell_exec",
    "Execute a shell command and return output (30s timeout, use with care)",
    {
      command: z.string().describe("Shell command to execute"),
      timeout: z.number().optional().describe("Timeout in ms (default: 30000, max: 300000)"),
      cwd: z.string().optional().describe("Working directory"),
    },
    async ({ command, timeout, cwd }) => {
      const ms = Math.min(timeout ?? 30_000, 300_000);
      const result = sh(command, { timeout: ms, cwd });
      return {
        content: [{ type: "text", text: formatResult("shell", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "npm_global_list",
    "List globally installed npm packages",
    {},
    async () => {
      const result = sh(`npm list -g --depth=0 2>/dev/null`);
      return { content: [{ type: "text", text: result.stdout || "No global packages" }] };
    }
  );

  server.tool(
    "npm_global_install",
    "Install or update a global npm package",
    {
      package: z.string().describe("Package name (e.g. @anthropic-ai/claude-code@latest)"),
    },
    async ({ package: pkg }) => {
      const result = sh(`npm install -g "${pkg}" 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`npm -g install ${pkg}`, result) }],
        isError: !result.ok,
      };
    }
  );
}
