---
name: status
description: List a contextualizer's reference freshness and any pending review work.
---

# Status

Read-only one-page dashboard. Lists fresh / stale / critical references by age,
notes pending proposals waiting on human review, and surfaces any recent
rejection-log clustering that suggests a doctrine gap.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at one of three install levels:

- **User-level:** `~/.claude/skills/<slug>-context/`
- **Local-user-level:** `~/.claude/local/skills/<slug>-context/` (when in use)
- **Project-level:** `<repo>/.claude/skills/<slug>-context/`

Every path below — `research/...`, `references/...`, `verify.sh` —
resolves relative to whichever directory matches. Before reading
anything, locate the root by searching all three install levels in
order:

<!-- doctrine:locator-block:start -->
```bash
set -euo pipefail
# <name> resolves per this skill's "Selecting a contextualizer" section;
# substitute the empty string when no contextualizer was named.
name="<name>"
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    if [ -n "$name" ]; then
      find "$root" -mindepth 1 -maxdepth 1 -type d -name "${name}-context" 2>/dev/null
    else
      find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
    fi
  done
)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ] && [ -n "$name" ]; then
  echo "No contextualizer named ${name}-context under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Rerun with no name to list what is installed."
  exit 1
elif [ "$n" -eq 0 ]; then
  echo "No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ] && [ -n "$name" ]; then
  # Same slug installed at more than one level: the first root in the
  # search order above wins (user, then local-user, then project).
  CTX_ROOT=$(printf '%s\n' "$ctx_roots" | head -n1)
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; rerun naming one (see 'Selecting a contextualizer' in this skill):"
  printf '%s\n' "$ctx_roots"
  exit 1
else
  CTX_ROOT="$ctx_roots"
fi
```
<!-- doctrine:locator-block:end -->

### Selecting a contextualizer

`/skill-engine:status <name>` names the contextualizer to report on:
`<name>` is the directory name without the `-context` suffix, the same
grammar `review`/`apply`/`discard` use. Substitute it (or the empty
string) for `<name>` in the locator above. With no argument,
auto-detection applies — it succeeds when exactly one contextualizer is
installed and lists the matches and exits when more than one is.

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

## Pending proposals

A staged-but-unapplied proposal sits as a sibling of the live tree at
`${CTX_ROOT}.proposed/`. STATUS surfaces it (and how far its review has
progressed) so a pending review does not silently rot — this is the
"notes pending proposals waiting on human review" the intro promises.
Read-only: STATUS reports the proposal's state but never advances it.

```bash
slug=$(basename "$CTX_ROOT"); slug="${slug%-context}"
proposed="${CTX_ROOT}.proposed"
if [ ! -d "$proposed" ]; then
  printf 'No pending proposal (nothing staged).\n'
else
  manifest="$proposed/.review/manifest.json"
  review="$proposed/.review/REVIEW.md"
  if [ -f "$manifest" ]; then
    added=$(jq '[.entries[]|select(.status=="added")]|length'    "$manifest" 2>/dev/null); added=${added:-0}
    modified=$(jq '[.entries[]|select(.status=="modified")]|length' "$manifest" 2>/dev/null); modified=${modified:-0}
    removed=$(jq '[.entries[]|select(.status=="removed")]|length'  "$manifest" 2>/dev/null); removed=${removed:-0}
    printf 'Pending proposal: %s.proposed/  (%s added, %s modified, %s removed)\n' \
      "$slug" "$added" "$modified" "$removed"
  else
    printf 'Pending proposal: %s.proposed/  (incomplete — no manifest; DISCOVER/REFRESH did not finish)\n' "$slug"
  fi
  # Review progress, mirroring apply's pre-promotion gates (read-only here).
  if [ -f "$review" ]; then
    ticks=$(grep -ciE '^- \[x\] (reviewed|provisional|reject)' "$review" 2>/dev/null); ticks=${ticks:-0}
    if grep -q '___' "$review" 2>/dev/null; then
      printf '  Review: awaiting Step 1 predictions (run /skill-engine:review %s).\n' "$slug"
    elif grep -qF '(Run /skill-engine:review' "$review" 2>/dev/null; then
      printf '  Review: Step 1 filled; Step 2 not yet generated (re-run /skill-engine:review %s).\n' "$slug"
    elif [ "$ticks" -eq 1 ]; then
      state=$(grep -iE '^- \[x\] (reviewed|provisional|reject)' "$review" | head -1 | sed -E 's/^- \[[xX]\] +//')
      printf '  Review: signed off as %s — ready for /skill-engine:apply %s.\n' "$state" "$slug"
    else
      printf '  Review: not yet signed off (tick one Step 3 box, then /skill-engine:apply %s).\n' "$slug"
    fi
  fi
fi
```

## Doctrine surface

The STATUS workflow — what it renders, how it sorts, when it pre-renders vs.
runs on demand — lives in chapter [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md) and the `## Workflow: STATUS`
section of [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template).

The freshness categories (fresh, stale, critical) and their default thresholds
are documented in chapter [`05-invariants.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/05-invariants.md).

## Cadence

Quick read; run anytime. STATUS does not write, so it is a safe first step on
returning to a contextualizer after a gap.

## Cache surface

The on-demand DISCOVER/REFRESH local clone cache lives at
`~/.cache/skill-engine/git-managed/<source_id>-<sha>/` (see
`engine-bootstrap/SKILL.md` for the convention). The cache is persistent
and not auto-cleaned at end of a workflow, so it can accumulate disk
usage as upstream SHAs advance.

STATUS surfaces the cache so the user can see what is on disk:

```bash
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine"
if [ -d "$cache_root" ]; then
  printf '%s\n' "Cache root: $cache_root"
  total=$(du -sh "$cache_root" 2>/dev/null | awk '{print $1}')
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
else
  printf '%s\n' "Cache root not present at $cache_root (cold cache; nothing to report)."
fi
```

The cache section is informational — STATUS does not delete anything.
REFRESH auto-GCs stale SHA directories; `/skill-engine:clean-cache`
deletes the cache on demand.

If multiple `<source_id>-*/` directories exist for the same `source_id`
(i.e., older SHAs were not GC'd because REFRESH has not run yet), flag
them as a hint in the Cache section, but do not delete.

### Cache listing

`~/.cache/skill-engine/git-managed/`:
| source_id | sha | last_fetched |
|---|---|---|
| ... | ... | ... |

`~/.cache/skill-engine/web-doc/`:
| source_id | crawl_id | page_count | crawl_date | decay_remaining |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

Old flat-layout entries (if present):
| dir | last_modified |
|---|---|
| ~/.cache/skill-engine/<source_id>-<sha>/ | ... | <!-- doctrine:legacy-cache-layout -->

(The old-layout listing exists until the user runs the REFRESH migration
prompt or `clean-cache`.)

## Invariants

STATUS is read-only. It surfaces findings; it does not propose edits, does not
fetch upstream, and does not modify `research/.research-state.json`. The
underlying state read uses a pre-render guard so the dashboard never blocks on
a partial write. The Cache section is read-only too: STATUS reports cache
state but never deletes from it.
