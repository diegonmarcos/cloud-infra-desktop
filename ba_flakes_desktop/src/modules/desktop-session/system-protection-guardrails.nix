# Guardrails — RETIRED (dead-code removed 2026-07-08, PLAN-hardening §1C U3)
#
# ── What this module used to be ────────────────────────────────────────────
# A ~250-line generator that wrote PATH-shadowing wrapper scripts into
# ~/.local/bin/ for ~30 commands (npm, docker, nix, cargo, …) implementing four
# tiers: WHITELIST (pass) · BLOCKED (hard-stop destructive flags like
# `docker compose down -v`) · CONFIRM (y/N prompt) · WARNING (banner).
# It also prepended ~/.local/bin to PATH via programs.bash.{initExtra,profileExtra}.
#
# ── Why it is DELETED, not re-enabled ──────────────────────────────────────
# The entire output (`programs.bash.*` + `home.file`) was commented out and
# labelled "TEMPORARILY DISABLED for login debugging". Investigated for U3:
#
#   1. DEAD — the module body has produced NOTHING across the 77-leaf split
#      refactor; it is imported by desktop-session/system-protection.nix purely
#      as a no-op. The huge `let` (whitelist/blocked/mkWrapper/…) was never forced.
#
#   2. RE-ENABLING IS BROKEN — the split moved this file into desktop-session/
#      but left `import ./managed-header.nix`; the real file is one level up at
#      ../managed-header.nix. Uncommenting the body forces `managed` and fails
#      nix eval with "path does not exist". So it could never be re-enabled as-is.
#
#   3. RE-ENABLING IS RISKY — it was disabled precisely because the PATH wrappers
#      broke login (the CONFIRM tier's `read -t 5` on session-init commands). The
#      SDDM/Plasma bypass added later was never trusted enough to flip it back on.
#
#   4. REDUNDANT — every protection it offered is already enforced upstream and
#      more reliably: the Claude Code Tier-C₁ Bash hooks hard-deny `git add -f`,
#      `docker compose down -v|--volumes`, `docker volume rm|prune`, etc. (see
#      ~/.claude/CLAUDE.md §E.1.2), and the cloud pre-commit hook blocks
#      gitignored/secret stages. A per-shell PATH wrapper is weaker (bypassed by
#      absolute paths, non-bash shells, env) and login-fragile.
#
#   5. SIBLING PRECEDENT — the VM-side equivalent
#      cloud/b_infra/_shared/vm-pilot/src/modules/protection/guardrails.nix is
#      likewise disabled ("POSIX sh bug"). This whole PATH-wrapper approach is
#      superseded by the hook layer on both desktop and VMs.
#
# If a shell-level guardrail is ever wanted again, resurrect from git history
# (commit 7881b10e and earlier), fix the ../managed-header.nix path, and re-test
# the login path before enabling — do not just uncomment.
{ ... }:
{
  # Intentionally empty. See header for the U3 delete-vs-reenable rationale.
}
