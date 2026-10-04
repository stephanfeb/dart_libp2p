# Beads Workflow Context

> **Context Recovery**: Run `bd prime` after compaction, clear, or new session.

This repository runs beads 1.x with an embedded database (`.beads/embeddeddolt`,
not tracked), no Dolt remote and no daemon. `.beads/issues.jsonl` is the tracked
copy: it goes to GitHub with the code. Do not run `bd sync` and do not set
`sync.remote`.

## Session close protocol

Before saying "done" or "complete", one step at a time:

```
[ ] 1. bd close <id1> <id2> ...         (close completed issues; children before their parent)
[ ] 2. run quality gates                (tests, linters, builds when relevant)
[ ] 3. bd export -o .beads/issues.jsonl
[ ] 4. git add <files> .beads/issues.jsonl && git commit -m "..."
[ ] 5. git pull --rebase
[ ] 6. git push && git status           (must show "up to date with origin")
```

Commit and push follow the user's instructions and the repository's AGENTS.md.
Do not install git hooks (`bd hooks install`): this setup has none.

## Commands

- `bd ready` - issues with no blockers
- `bd list --status=open` / `--status=in_progress`
- `bd show <id>` - details and dependencies
- `bd create --title="..." --description="..." --type=task|bug|feature --priority=2` (priority 0-4, not words)
- `bd create ... --parent=<id>` - child of an epic
- `bd update <id> --status=in_progress` - claim work
- `bd update <id> --append-notes="..."` - add to notes (`--notes` replaces them)
- `bd close <id> --reason="..."`; several ids at once are allowed. A parent cannot close while a child is open: close the children first
- `bd dep add <issue> <depends-on>`; `bd blocked`
