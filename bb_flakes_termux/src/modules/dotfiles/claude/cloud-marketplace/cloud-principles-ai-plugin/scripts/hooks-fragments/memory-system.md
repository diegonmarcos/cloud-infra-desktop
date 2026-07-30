# Memory System — Structure Rule

Claude Code loads **ALL `.md` files sitting directly in the memory root** unconditionally at
session start. UNCONDITIONAL LOADING OF ENTRY FILES IS FORBIDDEN — `MEMORY.md` is an index for
Claude to decide what's worth reading, not a bundle to preload. To prevent 46k+ token waste
(was ~25% of context window), only `MEMORY.md` lives at the root. Every individual entry file
goes in a topic subfolder — never loose at the root.

## MANDATORY: Writing Memory Files

- **ALWAYS** write new memory files to `<type>/<name>.md` (`feedback/`, `project/`, `reference/`,
  or `user/`) — NEVER to the memory root
- **ALWAYS** add a one-line pointer in `MEMORY.md` linking to `<type>/<name>.md`
- The root memory directory must contain ONLY `MEMORY.md` and the four type subfolders — no
  loose `.md` files, ever. If one appears at the root, move it into its type subfolder and fix
  the link.

## Structure

```
memory/
├── MEMORY.md      ← index only, auto-loaded each session
├── feedback/      ← behavioral rules, loaded on demand via Read tool
├── project/       ← ongoing work/plans, loaded on demand via Read tool
├── reference/      ← pointers to external systems, loaded on demand via Read tool
└── user/          ← user profile/preferences, loaded on demand via Read tool
```

## Reading Memory

Read `MEMORY.md` (already in context) to find relevant entries, then use the Read tool on
`<type>/<name>.md` only when that context is needed for the current task.
