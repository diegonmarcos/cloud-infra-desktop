// Git tools — repo status, log, diff across all tracked repos
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { bash, formatResult } from "../exec.js";
import { GIT_ROOT } from "../paths.js";

const REPOS = ["unix", "cloud", "front", "vault", "tools"];

export function registerGitTools(server: McpServer) {
  server.tool(
    "git_status_all",
    "Show git status across all tracked repos (unix, cloud, front, vault, tools)",
    {},
    async () => {
      const lines: string[] = [];
      for (const repo of REPOS) {
        const result = bash(
          `cd "${GIT_ROOT}/${repo}" 2>/dev/null && echo "=== ${repo} ($(git branch --show-current)) ===" && git status -s | head -20 || echo "=== ${repo}: not found ==="`,
          { timeout: 10_000 }
        );
        lines.push(result.stdout.trim());
      }
      return { content: [{ type: "text", text: lines.join("\n\n") }] };
    }
  );

  server.tool(
    "git_log",
    "Show recent git log for a repo",
    {
      repo: z.enum(["unix", "cloud", "front", "vault", "tools"]).describe("Repository name"),
      count: z.number().optional().describe("Number of commits (default: 10)"),
    },
    async ({ repo, count }) => {
      const n = count ?? 10;
      const result = bash(
        `git -C "${GIT_ROOT}/${repo}" log --oneline -${n} 2>&1`,
        { timeout: 10_000 }
      );
      return {
        content: [{ type: "text", text: result.ok ? result.stdout : formatResult("git log", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "git_diff",
    "Show git diff for a repo (staged or unstaged)",
    {
      repo: z.enum(["unix", "cloud", "front", "vault", "tools"]).describe("Repository name"),
      staged: z.boolean().optional().describe("Show staged changes (default: false)"),
    },
    async ({ repo, staged }) => {
      const flag = staged ? "--cached" : "";
      const result = bash(
        `git -C "${GIT_ROOT}/${repo}" diff ${flag} 2>&1 | head -200`,
        { timeout: 10_000 }
      );
      return {
        content: [{ type: "text", text: result.ok ? (result.stdout || "No changes") : formatResult("git diff", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "git_remote_status",
    "Check if repos are ahead/behind their remote",
    {},
    async () => {
      const lines: string[] = [];
      for (const repo of REPOS) {
        const result = bash(
          `cd "${GIT_ROOT}/${repo}" 2>/dev/null && git fetch --dry-run 2>&1; echo "$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo '? ?')" | awk '{print "'${repo}': ahead="$1" behind="$2}'`,
          { timeout: 15_000 }
        );
        lines.push(result.stdout.trim());
      }
      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );
}
