# Memory System — Structure Rule

Claude Code loads **ALL `.md` files** in the memory directory unconditionally at session start.
To prevent 46k+ token waste, only `MEMORY.md` lives at the root. Individual files go in `entries/`.

## MANDATORY: Writing Memory Files

- **ALWAYS** write new memory files to `entries/<name>.md` — NEVER to the memory root
- **ALWAYS** add a one-line pointer in `MEMORY.md` linking to `entries/<name>.md`
- The root memory directory must contain ONLY `MEMORY.md` and the `entries/` subdirectory

## Structure

```
memory/
├── MEMORY.md          ← index only, auto-loaded each session
└── entries/
    ├── feedback_*.md  ← loaded on demand via Read tool
    ├── project_*.md
    └── reference_*.md
```

## Reading Memory

Read `MEMORY.md` (already in context) to find relevant entries, then use the Read tool on `entries/<name>.md` only when that context is needed for the current task.
