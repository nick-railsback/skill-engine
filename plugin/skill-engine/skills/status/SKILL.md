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
skill at `.claude/skills/<slug>-context/`. Every path below —
`research/...`, `references/...`, `verify.sh` — resolves relative to that
directory.

Before reading anything, locate the root from the project working
directory:

```bash
ctx_roots=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under .claude/skills/*-context/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers under .claude/skills/; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
```

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

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
`~/.cache/skill-engine/<source_id>-<sha>/` (see
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
| ~/.cache/skill-engine/<source_id>-<sha>/ | ... |

(The old-layout listing exists until the user runs the REFRESH migration
prompt or `clean-cache`.)

## Invariants

STATUS is read-only. It surfaces findings; it does not propose edits, does not
fetch upstream, and does not modify `research/.research-state.json`. The
underlying state read uses a pre-render guard so the dashboard never blocks on
a partial write. The Cache section is read-only too: STATUS reports cache
state but never deletes from it.
