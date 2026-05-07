#!/usr/bin/env bash
# gen-claude-md.sh — Generate CLAUDE.md from template + cloud topology
# Called by home-manager activation to inject dynamic infrastructure data.
# Source: build-flakes_desktop.json (vms, services slices) emitted by
# 2_configs/src/engines/cloud-data-config-derive.ts via external-consumers.json.
set -euo pipefail

TPL="${1:-$HOME/.claude/CLAUDE.md.tpl}"
OUT="${2:-$HOME/.claude/CLAUDE.md}"
# Priority chain: synced copy → cloud repo dist → legacy cloud-data dir.
TOPOLOGY=""
for _p in \
    "${3:-}/build-flakes_desktop.json" \
    "$HOME/git/unix/ba_flakes_desktop/build-flakes_desktop.json" \
    "$HOME/git/cloud/2_configs/dist/build-flakes_desktop.json" \
    "${3:-$HOME/git/cloud/cloud-data}/cloud-data-topology.json"; do
  [ -f "$_p" ] && { TOPOLOGY="$_p"; break; }
done
NODE="${NODE_BIN:-node}"

# Fallback: if topology source or node not available, strip markers and use template as-is
if [ -z "$TOPOLOGY" ] || [ ! -f "$TPL" ]; then
  echo "[gen-claude-md] WARNING: cloud-data or template not found, using static fallback"
  if [ -f "$TPL" ]; then
    "$NODE" -e '
      const fs = require("fs");
      const tpl = fs.readFileSync(process.argv[1], "utf8");
      const out = tpl.replace(/^<!-- INJECT:[a-z_]+ -->\n/gm, "")
                     .replace(/^<!-- \/INJECT -->\n/gm, "");
      fs.writeFileSync(process.argv[2], out);
    ' "$TPL" "$OUT" 2>/dev/null || cp "$TPL" "$OUT"
  fi
  exit 0
fi

# Render fish greeting (strip ANSI escape codes for markdown)
FISH_GREETING=""
if command -v fish >/dev/null 2>&1; then
  FISH_GREETING=$(fish -c '_show_welcome' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true)
fi
if [ -z "$FISH_GREETING" ]; then
  FISH_GREETING="(fish greeting not available — fish not installed or greeting failed)"
fi

# ── Repo directory trees (-L 4, dirs only, plain ASCII indent) ─────────────
# Data-driven via REPO_TREES_LIST (defaults to: unix cloud front vault tools).
# Plain 2-space indented output instead of unicode tree art (├──, │, └──) —
# halves the token cost (~7k vs ~14k for 5-repo monorepo at depth 4).
#
# find + awk over plain `tree` because:
#   1. No unicode characters → cheaper BPE token count
#   2. Skip-prune of build artefacts is built into find
#   3. No tree dependency at activation time on minimal hosts
GIT_BASE_DIR="${GIT_BASE_DIR:-$HOME/git}"
REPO_TREES_LIST="${REPO_TREES_LIST:-unix cloud front vault tools}"
TREE_DEPTH="${TREE_DEPTH:-4}"
REPO_TREES=""
# `$'...'` doesn't unescape backticks; build the fence as a plain literal.
FENCE='```'
NL=$'\n'
for _repo in $REPO_TREES_LIST; do
  _path="$GIT_BASE_DIR/$_repo"
  [ -d "$_path" ] || continue
  _tree=$(cd "$GIT_BASE_DIR" && find "$_repo" -maxdepth "$TREE_DEPTH" -type d \
      \( -name node_modules -o -name .git -o -name dist -o -name .cache \
      -o -name target -o -name build -o -name .next -o -name .svelte-kit \
      -o -name .result -o -name snapshots -o -name .terraform \) -prune \
      -o -type d -print 2>/dev/null | sort | awk -F/ '{
          indent = ""
          for (i=1; i<NF; i++) indent = indent "  "
          print indent $NF "/"
      }')
  REPO_TREES="${REPO_TREES}### \`~/git/${_repo}/\`${NL}${NL}${FENCE}${NL}${_tree}${NL}${FENCE}${NL}${NL}"
done
if [ -z "$REPO_TREES" ]; then
  REPO_TREES="(no repos found under $GIT_BASE_DIR — REPO_TREES_LIST=$REPO_TREES_LIST)"
fi

# All-in-one: read template + topology, inject dynamic sections, write output
"$NODE" -e '
const fs = require("fs");
const tpl = fs.readFileSync(process.argv[1], "utf8");
const topo = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outPath = process.argv[3];
const fishGreeting = process.argv[4] || "(fish greeting not available)";
const repoTrees = process.argv[5] || "(repo trees not generated)";

const vms = topo.vms || {};
const services = topo.services || {};

// --- B.2 Virtual Machines ---
const vmRows = [];
for (const [id, vm] of Object.entries(vms)) {
  if (!vm.ip || vm.ip === "TBD") continue;
  const vmServices = Object.entries(services)
    .filter(([,s]) => s.vm === id && s.domain)
    .map(([name]) => name);
  const svcSummary = vmServices.slice(0, 4).join(", ")
    + (vmServices.length > 4 ? ` (+${vmServices.length - 4} more)` : "");
  vmRows.push({
    id, alias: vm.ssh_alias || "\u2014", ip: vm.ip,
    wg: vm.wg_ip || "\u2014", desc: vm.description || "\u2014",
    services: svcSummary || "\u2014"
  });
}

let vmTable = "| VM | Alias | IP | WG IP | Description |\n";
vmTable += "|----|-------|-----|-------|-------------|\n";
for (const r of vmRows) {
  vmTable += `| ${r.id} | ${r.alias} | ${r.ip} | ${r.wg} | ${r.desc} |\n`;
}
vmTable = vmTable.trimEnd();

// --- B.3 SSH aliases ---
const aliases = vmRows.map(r => r.alias).filter(a => a !== "\u2014");
const sshLine = "SSH aliases: " + aliases.map(a => "`ssh " + a + "`").join(", ") + ".";

// --- B.4 Active Services (only those with domains) ---
const svcRows = [];
for (const [name, svc] of Object.entries(services)) {
  if (!svc.domain) continue;
  const vmAlias = vms[svc.vm]?.ssh_alias || svc.vm || "local";
  svcRows.push({ name, domain: svc.domain, vm: vmAlias, category: svc.category || "\u2014" });
}
svcRows.sort((a, b) => a.vm.localeCompare(b.vm) || a.name.localeCompare(b.name));

let svcTable = "| Service | Domain | VM | Category |\n";
svcTable += "|---------|--------|-----|----------|\n";
for (const r of svcRows) {
  svcTable += `| ${r.name} | ${r.domain} | ${r.vm} | ${r.category} |\n`;
}
svcTable = svcTable.trimEnd();

const generated = new Date().toISOString().split("T")[0];
const genLine = `> **Auto-generated**: ${generated} from cloud-data (${vmRows.length} VMs, ${svcRows.length} services with domains)`;

// --- Injection map ---
const injections = {
  vm_table: vmTable,
  ssh_aliases: sshLine,
  services_table: svcTable,
  generated_date: genLine,
  fish_greeting: fishGreeting,
  repo_trees: repoTrees,
};

// Process template: replace <!-- INJECT:name --> ... <!-- /INJECT --> blocks
const lines = tpl.split("\n");
const out = [];
let skip = false;

for (const line of lines) {
  const injectMatch = line.match(/^<!-- INJECT:([a-z_]+) -->$/);
  if (injectMatch) {
    const name = injectMatch[1];
    if (injections[name] !== undefined) {
      out.push(injections[name]);
    }
    skip = true;
    continue;
  }
  if (line.match(/^<!-- \/INJECT -->$/)) {
    skip = false;
    continue;
  }
  if (!skip) {
    out.push(line);
  }
}

fs.writeFileSync(outPath, out.join("\n"));
console.error(`[gen-claude-md] Generated CLAUDE.md (${vmRows.length} VMs, ${svcRows.length} services, date=${generated})`);
' "$TPL" "$TOPOLOGY" "$OUT" "$FISH_GREETING" "$REPO_TREES"
