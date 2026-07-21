# Claude Code agents — fleet design

Source of truth for `~/.claude/agents/` (deployed declaratively by HM dotfiles).

## Design rules
1. **Model policy: every agent pins `model: sonnet`.** Agents are workers —
   the orchestrating session picks the expensive brain; workers stay cheap,
   fast, and predictable. Never `opus`/inherit in an agent definition.
2. **One agent = one job.** Small description, tight tool list. No
   god-agents.
3. **Read-only by default.** Only `build` and `ops` get write/exec tools.
4. Format: markdown + YAML frontmatter (`name`, `description`, `tools`,
   `model`) — the standard Claude Code agent manifest.

## Roster
| agent   | job                                   | tools        |
|---------|---------------------------------------|--------------|
| explore | find code/files/facts, report back    | read-only    |
| build   | implement a scoped change             | full         |
| review  | adversarially verify a claim or diff  | read-only    |
| ops     | CI/CD, gh runs, docker, deploy checks | bash + read  |
