// System tools — platform info, environment, processes, disk
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../exec.js";
import { PLATFORM } from "../paths.js";

export function registerSystemTools(server: McpServer) {
  server.tool(
    "sys_info",
    "Show system information (platform, kernel, memory, disk, nix version)",
    {},
    async () => {
      const result = sh(`
        echo "platform: ${PLATFORM}"
        echo "kernel: $(uname -r)"
        echo "arch: $(uname -m)"
        echo "nix: $(nix --version 2>/dev/null || echo 'not found')"
        echo "node: $(node --version 2>/dev/null || echo 'not found')"
        echo ""
        echo "--- memory ---"
        free -h 2>/dev/null || echo "free not available"
        echo ""
        echo "--- disk ---"
        df -h / $HOME 2>/dev/null | head -5
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "sys_env",
    "Show relevant environment variables (PATH, NIX, NODE, SHELL)",
    {},
    async () => {
      const result = sh(`
        for var in PATH SHELL HOME USER NODE_PATH NIX_PATH LD_PRELOAD PLATFORM; do
          val="$(printenv "$var" 2>/dev/null || echo '<unset>')"
          printf "%-15s %s\n" "$var" "$val"
        done
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "sys_which",
    "Check if tools are available and show their paths (uses command -v)",
    {
      tools: z.string().describe("Space-separated list of tool names (e.g. 'git nix jq curl')"),
    },
    async ({ tools }) => {
      const result = sh(`
        for t in ${tools}; do
          path="$(command -v "$t" 2>/dev/null)"
          if [ -n "$path" ]; then
            printf "%-20s %s\n" "$t" "$path"
          else
            printf "%-20s NOT FOUND\n" "$t"
          fi
        done
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "sys_processes",
    "Show running processes (filtered by optional pattern)",
    {
      pattern: z.string().optional().describe("Grep pattern to filter processes"),
    },
    async ({ pattern }) => {
      const cmd = pattern
        ? `ps aux 2>/dev/null | head -1; ps aux 2>/dev/null | grep -i "${pattern}" | grep -v grep | head -30`
        : `ps aux 2>/dev/null | head -20`;
      const result = sh(cmd);
      return { content: [{ type: "text", text: result.stdout || "No processes found" }] };
    }
  );

  server.tool(
    "sys_installed_packages",
    "List nix-profile installed packages",
    {},
    async () => {
      const result = sh(`nix-env -q 2>/dev/null || ls ~/.nix-profile/bin/ 2>/dev/null | sort`);
      return {
        content: [{ type: "text", text: result.ok ? result.stdout : formatResult("packages", result) }],
        isError: !result.ok,
      };
    }
  );
}
