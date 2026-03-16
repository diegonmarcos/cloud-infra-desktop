// Nix ecosystem tools — flake operations, package queries, build system
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { bash, exec, formatResult } from "../exec.js";
import { UNIX_ROOT, FLAKE_TERMUX, FLAKE_DESKTOP, FLAKE_HOST, PLATFORM } from "../paths.js";
import { join } from "path";
import { readFileSync, existsSync } from "fs";

const FLAKE_MAP: Record<string, string> = {
  termux: join(FLAKE_TERMUX, "src"),
  desktop: join(FLAKE_DESKTOP, "src"),
  host: join(FLAKE_HOST, "src"),
};

export function registerNixTools(server: McpServer) {
  server.tool(
    "nix_flake_info",
    "Show flake metadata (inputs, revisions, dates) for a given flake",
    {
      flake: z.enum(["termux", "desktop", "host"]).describe("Which flake to inspect"),
    },
    async ({ flake }) => {
      const dir = FLAKE_MAP[flake];
      if (!dir || !existsSync(join(dir, "flake.lock"))) {
        return { content: [{ type: "text", text: `Flake not found: ${flake}` }], isError: true };
      }
      const lock = JSON.parse(readFileSync(join(dir, "flake.lock"), "utf-8"));
      const inputs = lock.nodes?.root?.inputs ?? {};
      const summary: string[] = [`Flake: ${flake} (${dir})\n`];
      for (const [name, nodeRef] of Object.entries(inputs)) {
        const node = lock.nodes?.[nodeRef as string];
        if (!node?.locked) continue;
        const rev = node.locked.rev?.slice(0, 7) ?? "?";
        const ref = node.original?.ref ?? "";
        const date = node.locked.lastModified
          ? new Date(node.locked.lastModified * 1000).toISOString().slice(0, 10)
          : "?";
        const narHash = node.locked.narHash ?? "";
        summary.push(`  ${name}: rev=${rev} ref=${ref} date=${date} hash=${narHash}`);
      }
      return { content: [{ type: "text", text: summary.join("\n") }] };
    }
  );

  server.tool(
    "nix_flake_update_input",
    "Update a specific flake input (runs nix flake lock --update-input)",
    {
      flake: z.enum(["termux", "desktop", "host"]).describe("Which flake"),
      input: z.string().describe("Input name (e.g. nixpkgs, nixpkgs-new, home-manager)"),
    },
    async ({ flake, input }) => {
      const dir = FLAKE_MAP[flake];
      const result = bash(`cd "${dir}" && nix flake lock --update-input "${input}"`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`Update ${flake}/${input}`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_build_switch",
    "Run build.sh switch for a flake (applies config)",
    {
      flake: z.enum(["termux", "desktop", "host"]).describe("Which flake to switch"),
    },
    async ({ flake }) => {
      const flakeRoot: Record<string, string> = {
        termux: FLAKE_TERMUX,
        desktop: FLAKE_DESKTOP,
        host: FLAKE_HOST,
      };
      const buildSh = join(flakeRoot[flake], "build.sh");
      if (!existsSync(buildSh)) {
        return { content: [{ type: "text", text: `No build.sh at ${buildSh}` }], isError: true };
      }
      const result = exec("sh", [buildSh, "switch"], { timeout: 600_000, cwd: flakeRoot[flake] });
      return {
        content: [{ type: "text", text: formatResult(`build.sh switch (${flake})`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_search",
    "Search nixpkgs for a package by name",
    {
      query: z.string().describe("Package name to search"),
      channel: z.string().optional().describe("Nixpkgs channel (default: nixpkgs)"),
    },
    async ({ query, channel }) => {
      const src = channel ?? "nixpkgs";
      const result = bash(`nix search ${src} "${query}" --json 2>/dev/null | head -c 8000`, { timeout: 60_000 });
      return {
        content: [{ type: "text", text: result.ok ? result.stdout || "No results" : formatResult("nix search", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_store_path",
    "Get the nix store path for a package (nix eval / nix path-info)",
    {
      package: z.string().describe("Package attribute (e.g. nixpkgs#jq)"),
    },
    async ({ package: pkg }) => {
      const result = bash(`nix path-info "${pkg}" 2>/dev/null`, { timeout: 60_000 });
      return {
        content: [{ type: "text", text: result.ok ? result.stdout.trim() : formatResult("nix path-info", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "nix_generations",
    "List nix profile generations (home-manager or system)",
    {
      profile: z.enum(["home-manager", "system", "nix-on-droid"]).optional()
        .describe("Which profile (default: auto-detect)"),
    },
    async ({ profile }) => {
      let cmd: string;
      if (profile === "system") {
        cmd = "nix-env --list-generations -p /nix/var/nix/profiles/system 2>/dev/null | tail -20";
      } else if (profile === "nix-on-droid" || PLATFORM === "termux") {
        cmd = "nix-env --list-generations -p /nix/var/nix/profiles/nix-on-droid 2>/dev/null | tail -20";
      } else {
        cmd = "home-manager generations 2>/dev/null | head -20";
      }
      const result = bash(cmd, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: result.ok ? result.stdout || "No generations found" : formatResult("generations", result) }],
        isError: !result.ok,
      };
    }
  );
}
