## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd export -o .beads/issues.jsonl` - Write the issues to the tracked file; commit it with the code (no `bd sync`: beads 1.x has no Dolt remote here)

For full workflow details: `bd prime`

