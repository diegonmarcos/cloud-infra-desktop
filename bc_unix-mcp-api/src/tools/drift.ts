// nix-drift tools — version drift detection across nix flakes ecosystem
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../exec.js";
import { UNIX_ROOT } from "../paths.js";
import { join } from "path";

const DRIFT_SCRIPT = join(UNIX_ROOT, "bb_flakes_termux/src/nix-version-drift.sh");

export function registerDriftTools(server: McpServer) {
  server.tool(
    "nix_drift",
    "Show version drift status of all tracked nix packages and flake inputs",
    {
      outputFormat: z.enum(["table", "json"]).optional().describe("Output format (default: json)"),
      outdatedOnly: z.boolean().optional().describe("Only show outdated entries"),
      filter: z.string().optional().describe("Filter by package name"),
    },
    async ({ outputFormat, outdatedOnly, filter }) => {
      const args = ["drift"];
      if (outputFormat !== "table") args.push("--json");
      if (outdatedOnly) args.push("--outdated");
      if (filter) args.push("--filter", filter);

      const result = sh(`"${DRIFT_SCRIPT}" ${args.join(" ")}`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: result.ok ? result.stdout : formatResult("nix-drift", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_drift_plan",
    "Compute update plan for outdated nix packages (dry-run by default)",
    {
      apply: z.boolean().optional().describe("Apply changes to source files (default: false/dry-run)"),
      package: z.string().optional().describe("Only plan for specific package"),
    },
    async ({ apply, package: pkg }) => {
      const args = ["plan"];
      if (apply) args.push("--apply");
      else args.push("--dry-run");
      if (pkg) args.push("--package", pkg);

      const result = sh(`"${DRIFT_SCRIPT}" ${args.join(" ")}`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult("nix-drift plan", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_drift_clean",
    "Clear nix-drift cache (version query results)",
    {},
    async () => {
      const result = sh(`"${DRIFT_SCRIPT}" clean`);
      return {
        content: [{ type: "text", text: formatResult("nix-drift clean", result) }],
        isError: !result.ok,
      };
    }
  );
}
