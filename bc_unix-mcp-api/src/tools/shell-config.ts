// Shell configuration tools — fish/bash aliases, functions, greeting, starship, guardrails
// All config lives in nix source files under bb_flakes_termux/src/modules/programs/shells/
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { sh, formatResult } from "../exec.js";
import { UNIX_ROOT } from "../paths.js";

const SHELLS_DIR = join(UNIX_ROOT, "bb_flakes_termux/src/modules/programs/shells");
const MODULES_DIR = join(UNIX_ROOT, "bb_flakes_termux/src/modules");

const SHELL_FILES: Record<string, string> = {
  "fish": join(SHELLS_DIR, "fish.nix"),
  "fish-greeting": join(SHELLS_DIR, "fish-greeting.nix"),
  "bash": join(SHELLS_DIR, "bash.nix"),
  "starship": join(SHELLS_DIR, "starship.nix"),
  "guardrails": join(MODULES_DIR, "guardrails.nix"),
};

function readNixFile(key: string): string {
  const path = SHELL_FILES[key];
  if (!path || !existsSync(path)) return `File not found: ${key}`;
  return readFileSync(path, "utf-8");
}

// Parse aliases from nix attribute set: name = "value";
function parseNixAttrs(content: string, blockName: string): Record<string, string> {
  const result: Record<string, string> = {};
  // Find the block: blockName = { ... };
  const re = new RegExp(`${blockName}\\s*=\\s*\\{([^}]+)\\}`, "s");
  const match = content.match(re);
  if (!match) return result;
  const block = match[1];
  // Parse each: key = "value";
  const lines = block.matchAll(/^\s*(?:"([^"]+)"|(\w+))\s*=\s*"([^"]+)"/gm);
  for (const m of lines) {
    const key = m[1] ?? m[2];
    result[key] = m[3];
  }
  return result;
}

// Parse functions from nix attribute set
function parseNixFunctions(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  // Simple one-liner: name = "body";
  const oneLiners = content.matchAll(/^\s{6}(\w+)\s*=\s*"([^"]+)"/gm);
  for (const m of oneLiners) {
    result[m[1]] = m[2];
  }
  // Multi-line: name = '' ... '';
  const multiLine = content.matchAll(/^\s{6}(\w+)\s*=\s*''([\s\S]*?)''/gm);
  for (const m of multiLine) {
    result[m[1]] = m[2].trim();
  }
  return result;
}

export function registerShellConfigTools(server: McpServer) {
  server.tool(
    "shell_list_aliases",
    "List all shell aliases (fish and bash) from nix config",
    {
      shell: z.enum(["fish", "bash", "both"]).optional().describe("Which shell (default: both)"),
    },
    async ({ shell }) => {
      const lines: string[] = [];

      if (shell !== "bash") {
        const fishContent = readNixFile("fish");
        const fishAliases = parseNixAttrs(fishContent, "shellAliases");
        const fishAbbrs = parseNixAttrs(fishContent, "shellAbbrs");
        lines.push("=== Fish Aliases ===");
        for (const [k, v] of Object.entries(fishAliases)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
        lines.push("\n=== Fish Abbreviations ===");
        for (const [k, v] of Object.entries(fishAbbrs)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
      }

      if (shell !== "fish") {
        const bashContent = readNixFile("bash");
        const bashAliases = parseNixAttrs(bashContent, "shellAliases");
        lines.push("\n=== Bash Aliases ===");
        for (const [k, v] of Object.entries(bashAliases)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "shell_list_functions",
    "List all custom shell functions from nix config",
    {
      shell: z.enum(["fish", "bash", "both"]).optional().describe("Which shell (default: both)"),
    },
    async ({ shell }) => {
      const lines: string[] = [];

      if (shell !== "bash") {
        const fishContent = readNixFile("fish");
        const fishFns = parseNixFunctions(fishContent);
        lines.push("=== Fish Functions ===");
        for (const [name, body] of Object.entries(fishFns)) {
          const preview = body.split("\n")[0].slice(0, 60);
          lines.push(`  ${name.padEnd(14)} ${preview}${body.includes("\n") ? " ..." : ""}`);
        }
      }

      if (shell !== "fish") {
        lines.push("\n=== Bash Functions (in initExtra) ===");
        const bashContent = readNixFile("bash");
        // Extract function names from bash initExtra
        const fnMatches = bashContent.matchAll(/^\s{6}(\w+)\(\)\s*\{/gm);
        for (const m of fnMatches) {
          lines.push(`  ${m[1]}`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "shell_read_config",
    "Read the full nix source for a shell config file",
    {
      file: z.enum(["fish", "fish-greeting", "bash", "starship", "guardrails"])
        .describe("Which config file to read"),
    },
    async ({ file }) => {
      const content = readNixFile(file);
      const path = SHELL_FILES[file];
      return {
        content: [{ type: "text", text: `# ${path}\n\n${content}` }],
      };
    }
  );

  server.tool(
    "shell_greeting_preview",
    "Show the current fish greeting / welcome screen (runs it live)",
    {},
    async () => {
      const result = sh(`fish -c "fish_greeting" 2>&1`, { timeout: 10_000 });
      return {
        content: [{ type: "text", text: result.stdout || result.stderr || "No output" }],
      };
    }
  );

  server.tool(
    "shell_starship_config",
    "Show parsed starship prompt configuration (format, modules, symbols)",
    {},
    async () => {
      const content = readNixFile("starship");
      const lines: string[] = ["=== Starship Prompt Configuration ===\n"];

      // Extract format
      const fmtMatch = content.match(/format\s*=\s*lib\.concatStrings\s*\[([\s\S]*?)\]/);
      if (fmtMatch) {
        const segments = fmtMatch[1].matchAll(/"([^"]+)"/g);
        lines.push("Prompt format:");
        for (const s of segments) {
          lines.push(`  ${s[1]}`);
        }
        lines.push("");
      }

      // Extract module configs
      const modules = content.matchAll(/^\s{6}(\w+)\s*=\s*\{([\s\S]*?)\};/gm);
      for (const m of modules) {
        const name = m[1];
        const body = m[2];
        const symbol = body.match(/symbol\s*=\s*"([^"]+)"/)?.[1] ?? "";
        const format = body.match(/format\s*=\s*"([^"]+)"/)?.[1] ?? "";
        if (symbol || format) {
          lines.push(`${name}: symbol="${symbol}" format="${format}"`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "shell_guardrails_status",
    "Show guardrail tiers: which commands are whitelisted, blocked, confirm, or warning",
    {},
    async () => {
      const content = readNixFile("guardrails");
      const lines: string[] = ["=== Guardrail Tiers ===\n"];

      // Tier 0: whitelist
      lines.push("TIER 0 — WHITELIST (pass through):");
      const wlMatches = content.matchAll(/\{ cmd = "(\w+)"; subcommands = \[([\s\S]*?)\]/g);
      for (const m of wlMatches) {
        const subs = m[2].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")).join(", ") ?? "";
        lines.push(`  ${m[1].padEnd(16)} ${subs}`);
      }

      // Tier 1: blocked
      lines.push("\nTIER 1 — BLOCKED (hard stop):");
      const blMatches = content.matchAll(/\{ cmd = "([^"]+)";\s*match = "([^"]+)";\s*reason = "([^"]+)"/g);
      for (const m of blMatches) {
        lines.push(`  ${m[1]} ${m[2].padEnd(30)} ${m[3]}`);
      }

      // Tier 2: confirm
      lines.push("\nTIER 2 — CONFIRM (ask y/N):");
      const cfMatch = content.match(/confirmCmds\s*=\s*\[([\s\S]*?)\]/);
      if (cfMatch) {
        const cmds = cfMatch[1].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")) ?? [];
        lines.push(`  ${cmds.join(", ")}`);
      }

      // Tier 3: warning
      lines.push("\nTIER 3 — WARNING (banner then run):");
      const wrMatch = content.match(/warningCmds\s*=\s*\[([\s\S]*?)\]/);
      if (wrMatch) {
        const cmds = wrMatch[1].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")) ?? [];
        lines.push(`  ${cmds.join(", ")}`);
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "shell_active_aliases",
    "Show currently active aliases in fish or bash (live from running shell)",
    {
      shell: z.enum(["fish", "bash"]).optional().describe("Which shell (default: fish)"),
    },
    async ({ shell }) => {
      const cmd = (shell ?? "fish") === "fish"
        ? `fish -c "alias" 2>&1 | head -50`
        : `sh -c '. ~/.bashrc 2>/dev/null; alias' 2>&1 | head -50`;
      const result = sh(cmd, { timeout: 10_000 });
      return {
        content: [{ type: "text", text: result.stdout || result.stderr || "No aliases" }],
      };
    }
  );
}
