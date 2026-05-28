---
name: clean-cache
description: Delete the skill-engine clone cache (`~/.cache/skill-engine/`), with a dry-run preview first.
---

# Clean cache

Opt-in destructive command. Deletes the persistent local clone cache that DISCOVER and REFRESH populate under `~/.cache/skill-engine/`. Always dry-runs first; only deletes after explicit user confirmation.

## Usage

`/skill-engine:clean-cache [kind]`

`kind` is optional:
- omitted → clean every cache subtree under `~/.cache/skill-engine/`,
  including old flat-layout entries.
- `git-managed` → clean only `~/.cache/skill-engine/git-managed/`.
- `web-doc` → clean only `~/.cache/skill-engine/web-doc/`.

Always prompts with a list of directories before deletion. No deletion
happens without confirmation.

## What gets deleted

Everything under `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/`. The cache is partitioned by source kind:

- `~/.cache/skill-engine/git-managed/<source_id>-<sha>/` — shallow clones of git-backed upstream sources at a specific SHA.
- `~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/` — snapshots of crawled web documentation for a specific crawl.

Old flat-layout entries (`~/.cache/skill-engine/<source_id>-<sha>/`) may still exist if they predate the kind-partitioned layout and have not yet been migrated by REFRESH; this command will clean them too. The cache is regenerable: a subsequent DISCOVER or REFRESH against the same upstream re-creates whatever it needs from `gh`/`git` or the web crawler.

Nothing outside the cache root is touched. No contextualizer state (`.claude/skills/<slug>-context/`, including its `research/` and `references/` directories) is touched. No user files outside `~/.cache/skill-engine/` are touched.

## Workflow

```bash
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine"

if [ ! -d "$cache_root" ]; then
  printf '%s\n' "Cache root not present at $cache_root — nothing to clean."
  exit 0
fi

# Parse optional [kind] argument.
kind="${1:-}"
case "$kind" in
  ""|git-managed|web-doc) ;;
  *)
    printf 'ERROR: invalid kind %q (expected: git-managed, web-doc, or omitted)\n' "$kind" >&2
    exit 2
    ;;
esac
```

### Step 1: Dry-run preview

List the entries that would be deleted, scoped by `$kind` if set. Default to dry-run only — emit the list without deleting.

```bash
total=$(du -sh "$cache_root" 2>/dev/null | awk '{print $1}')
printf '%s\n' "Cache root: $cache_root"
[ -n "$kind" ] && printf '%s\n' "Kind filter: $kind"
printf '%s\n' "Total size: ${total:-0}"
printf '\n%-60s  %8s  %s\n' "Directory" "Size" "Last accessed"

# Build the list of directories in scope.
if [ -z "$kind" ]; then
  # All kinds + any legacy flat-layout entries at the cache root.
  scan_globs=( "$cache_root"/git-managed/*/ "$cache_root"/web-doc/*/ "$cache_root"/*/ )
else
  scan_globs=( "$cache_root/$kind"/*/ )
fi

for d in "${scan_globs[@]}"; do
  [ -d "$d" ] || continue
  base="$(basename "$d")"
  # Skip the kind subdirectories themselves when caught by the bare */ glob.
  if [ -z "$kind" ]; then
    [ "$base" = "git-managed" ] && continue
    [ "$base" = "web-doc" ] && continue
  fi
  sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
  accessed=$(stat -f '%Sa' -t '%Y-%m-%d' "$d" 2>/dev/null \
             || stat -c '%x' "$d" 2>/dev/null | cut -d' ' -f1)
  name="${d#"$cache_root"/}"
  name="${name%/}"
  printf '%-60s  %8s  %s\n' "$name" "$sz" "$accessed"
done
```

Surface the listing and ask the user to confirm. The confirmation phrasing should make the destructive scope explicit and name the kind filter when set:

> Delete the listed directories (total: <size>)?
> [if kind set:] Filter: only `<kind>` cache subtree.
> Reply `yes` to proceed, anything else to abort.

If the user does not reply with the literal word `yes`, abort without deleting.

**Worked example.** A typical dry-run with no kind filter, surfaced before the confirmation prompt, looks like:

```
Cache root: /Users/me/.cache/skill-engine
Total size: 135M

Directory                                                         Size  Last accessed
git-managed/django-django-cccc3333                                31M   2026-04-28
git-managed/vitejs-vite-aaaa1111                                  52M   2026-05-11
git-managed/vitejs-vite-bbbb2222                                  52M   2026-05-12
web-doc/anthropic-docs-eeee5555                                   42M   2026-05-15
legacy-flat-dddd4444                                              18M   2026-03-02

Delete the listed directories (total: 135M)?
A subsequent /skill-engine:discover or /skill-engine:refresh against any of
these sources will re-clone or re-crawl from upstream when run.

Reply `yes` to proceed, anything else to abort.
```

Two directories with the same `<source_id>` prefix (here, `vitejs-vite-*`) indicate REFRESH has not yet GC'd the older SHA — the older directory is stale and safe to remove. Entries directly under the cache root (here, `legacy-flat-dddd4444`) are pre-migration flat-layout cache; REFRESH's pre-flight step 1.5 normally relocates them on the next run.

When invoked with a `[kind]` argument, the preview lists only that subtree:

```
$ /skill-engine:clean-cache web-doc
Cache root: /Users/me/.cache/skill-engine
Kind filter: web-doc
Total size: 42M

Directory                                                         Size  Last accessed
web-doc/anthropic-docs-eeee5555                                   42M   2026-05-15
```

### Step 2: Deletion (only after confirmation)

```bash
if [ -z "$kind" ]; then
  # All kinds + legacy flat-layout entries.
  rm -rf -- "$cache_root"/git-managed/*/ "$cache_root"/web-doc/*/
  # Legacy flat entries (anything else directly under cache_root that is
  # a directory but not 'git-managed' or 'web-doc').
  for d in "$cache_root"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    [ "$base" = "git-managed" ] && continue
    [ "$base" = "web-doc" ] && continue
    rm -rf -- "$d"
  done
else
  rm -rf -- "$cache_root/$kind"/*/
fi
```

Notes:

- The `--` guards against any subdirectory name starting with `-`.
- Do NOT delete the cache root itself, nor the `git-managed/` or `web-doc/` kind subdirectories themselves — only their children.
- Do NOT follow symlinks. The `*/` glob expands only to directories, but be conservative: a symlinked directory should be inspected before deletion. If unsure, skip it.
- Do NOT delete anything outside the cache root, ever. The literal string `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/` must appear verbatim in the deletion path; never substitute, never accept user-supplied paths beyond the validated `kind` enum.

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
