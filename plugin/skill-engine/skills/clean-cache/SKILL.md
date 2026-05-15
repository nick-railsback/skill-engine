---
name: clean-cache
description: When the user wants to free disk space by deleting the skill-engine local clone cache (~/.cache/skill-engine/), with a dry-run preview before destructive action.
---

# Clean cache

Opt-in destructive command. Deletes the persistent local clone cache that DISCOVER and REFRESH populate under `~/.cache/skill-engine/`. Always dry-runs first; only deletes after explicit user confirmation.

## What gets deleted

Everything under `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/`. Each subdirectory is named `<source_id>-<sha>/` and holds a shallow clone of one upstream source at one SHA. The cache is regenerable: a subsequent DISCOVER or REFRESH against the same upstream re-creates whatever it needs from `gh`/`git`.

Nothing outside the cache root is touched. No contextualizer state (`.claude/skills/<slug>-context/`, including its `research/` and `references/` directories) is touched. No user files outside `~/.cache/skill-engine/` are touched.

## Workflow

```bash
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine"

if [ ! -d "$cache_root" ]; then
  printf '%s\n' "Cache root not present at $cache_root — nothing to clean."
  exit 0
fi
```

### Step 1: Dry-run preview

List every entry under the cache root with size and last-access date. Default to dry-run only — emit the list without deleting.

```bash
total=$(du -sh "$cache_root" 2>/dev/null | awk '{print $1}')
printf '%s\n' "Cache root: $cache_root"
printf '%s\n' "Total size: ${total:-0}"
printf '\n%-60s  %8s  %s\n' "Directory" "Size" "Last accessed"
for d in "$cache_root"/*/; do
  [ -d "$d" ] || continue
  sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
  accessed=$(stat -f '%Sa' -t '%Y-%m-%d' "$d" 2>/dev/null \
             || stat -c '%x' "$d" 2>/dev/null | cut -d' ' -f1)
  name=$(basename "$d")
  printf '%-60s  %8s  %s\n' "$name" "$sz" "$accessed"
done
```

Surface the listing and ask the user to confirm. The confirmation phrasing should make the destructive scope explicit: "Delete the listed directories (total: <size>)? Reply `yes` to proceed, anything else to abort."

If the user does not reply with the literal word `yes`, abort without deleting.

**Worked example.** A typical dry-run, surfaced before the confirmation prompt, looks like:

```
Cache root: /Users/me/.cache/skill-engine
Total size: 84M

Directory                                                         Size  Last accessed
vitejs-vite-aaaa1111                                              52M   2026-05-11
vitejs-vite-bbbb2222                                              52M   2026-05-12
flask-flask-cccc3333                                              31M   2026-04-28

Delete the listed directories (total: 84M)?
A subsequent /skill-engine:discover or /skill-engine:refresh against any of
these sources will re-clone from upstream into a fresh
~/.cache/skill-engine/<source_id>-<sha>/ when run.

Reply `yes` to proceed, anything else to abort.
```

Two directories with the same `<source_id>` prefix (here, `vitejs-vite-*`) indicate REFRESH has not yet GC'd the older SHA — the older directory is stale and safe to remove.

### Step 2: Deletion (only after confirmation)

```bash
rm -rf -- "$cache_root"/*/
```

Notes:

- `rm -rf -- "$cache_root"/*/` deletes only the immediate subdirectories of the cache root, not the cache root itself, and not any files at the cache root that are not directories. The `--` guards against any subdirectory name starting with `-`.
- Do NOT delete the cache root itself; subsequent DISCOVER/REFRESH runs may recreate it on demand and an extant root is fine.
- Do NOT follow symlinks. If any entry under the cache root is a symlink to outside the cache, the `*/` glob expands only to directories, but be conservative: a symlinked directory should be inspected before deletion. If unsure, skip it.
- Do NOT delete anything outside the cache root, ever. The literal string `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/` must appear verbatim in the deletion path; never substitute, never accept user-supplied paths.

### Step 3: Post-clean summary

After deletion, emit a one-line summary: "Deleted N directories, freed <size>." If a subsequent DISCOVER or REFRESH runs, it will re-clone from upstream into a fresh `~/.cache/skill-engine/<source_id>-<sha>/`.

## When to suggest this command

The user may want to clean the cache when:

- A contextualizer is finished and no REFRESH cycles are planned.
- Disk usage is a concern and `/skill-engine:status` shows accumulated cache directories.
- The user has rotated to a different project and the cached sources are no longer relevant.

This command is opt-in: nothing in the engine invokes it automatically.

## What this skill does NOT do

- It does not delete contextualizer state (no `.claude/skills/*-context/` directory is touched).
- It does not delete `source-paths.json` or any `references/` files.
- It does not unregister sources.
- It does not delete `~/.cache/skill-engine/` itself, only its immediate children.
- It does not run DISCOVER or REFRESH afterward — the user runs those separately when ready.

## Invariants

- Dry-run is the default; deletion requires explicit `yes`.
- Deletion scope is bounded to `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/*/`.
- No network access. No state writes to any contextualizer. Read-then-delete only.
