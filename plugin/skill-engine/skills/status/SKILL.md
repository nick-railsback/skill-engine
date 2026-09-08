---
name: status
description: Use when picking up a contextualizer after a gap, or checking reference freshness and pending review work at a glance — read-only, safe to run anytime.
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

Run the script in [`shared/locator-block.md`](../../shared/locator-block.md) verbatim before proceeding.

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
runs on demand — lives in chapter [`04-delivery.md`](../../docs/04-delivery.md) and the `## Workflow: STATUS`
section of [`maintenance-agent.md.template`](../../engine-bootstrap-templates/maintenance-agent.md.template).

The freshness categories (fresh, stale, critical) and their default thresholds
are documented in chapter [`05-invariants.md`](../../docs/05-invariants.md).

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

```bash
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine"
decay_json=$(python3 "$CLAUDE_PLUGIN_ROOT/tests/decay_check.py" research/source-paths.json "$cache_root" 2>/dev/null)
row_count=$(printf '%s' "$decay_json" | jq 'length' 2>/dev/null); row_count=${row_count:-0}
if [ "$row_count" -eq 0 ]; then
  printf '(No web-doc sources with a cached, decay-checkable snapshot yet.)\n'
else
  printf '%s' "$decay_json" | jq -r '
    .[] | "| \(.source_id) | \(.crawl_id) | \(.page_count) | \(.crawl_date) | " +
    (if .state == "non_expiring" then "no expiry"
     elif .state == "past_budget" then "\(.days) days past decay budget"
     else "\(.days) days remaining" end) + " |"'
fi
```

Old flat-layout entries (if present — directories sitting directly at the
cache root rather than under `git-managed/` or `web-doc/`):
| dir | last_modified |
|---|---|
| ... | ... |

(The old-layout listing exists until the user runs the REFRESH migration
prompt or `clean-cache`.)

## Priority surface

Render each in-scope source's `importance` (see
[`02-artifact-contract.md`](../../docs/02-artifact-contract.md) for
the field) and, when the root-level `probe_budget` is set, its
projected effect:

```python
import json
data = json.load(open('research/source-paths.json'))
sources = [s for s in data.get('sources', [])
           if not s.get('archived') and s.get('status') in ('confirmed', 'proposed')
           and s.get('lifecycle', {}).get('state') != 'removed']
print('| id | importance |')
print('|---|---|')
for s in sorted(sources, key=lambda s: s['id']):
    imp = s.get('importance')
    print(f"| {s['id']} | {imp if imp is not None else '3 (default)'} |")
budget = data.get('probe_budget')
k = len(sources)
if budget is not None:
    would_skip = max(0, k - budget)
    print(f'\nprobe_budget={budget}: would skip {would_skip} of {k} in-scope sources at the next refresh (worst case — assumes every source is promoted).')
else:
    print(f'\nprobe_budget not set: all {k} in-scope sources are probed every refresh.')
```

Run with `python3` against the contextualizer root
(`research/source-paths.json` relative to cwd), same convention as
`decay_check.py` elsewhere in this file. **Tag this fence `python`, not
`bash`** — `tests/status-decay/run.sh` sweeps every `` ```bash `` fence
in this file except the one inside whichever section's heading mentions
"probe" into its own decay-computation script; a `bash` tag here gets
swept in and breaks that sibling oracle.

`importance` defaults to `3 (default)` when the field is absent. The
skip count above is a worst-case estimate from the registry alone —
STATUS does not fetch upstream by default (see § Cadence), so it
cannot know in advance which sources will actually show drift this
session; `--probe` below can narrow that estimate for `git-managed`
sources at the cost of a live check.

## Provenance probe (`--probe`)

`/skill-engine:status <name> --probe` is an opt-in check: without
`--probe`, STATUS's behavior is exactly as documented above — it does
not fetch upstream. With `--probe`, STATUS runs one upstream check per
in-scope `git-managed` source in `research/source-paths.json` and
reports whether the locally recorded SHA still matches upstream today,
without waiting for a full REFRESH pass:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/tests/status_probe.py" research/source-paths.json
```

For each in-scope `git-managed` source (the same filter REFRESH's own
pre-flight uses: `status` confirmed or proposed, not archived, upstream
lifecycle state not removed), render one line from the script's JSON:

- **current** — the live SHA matches the recorded `last_checked_sha`.
- **mismatch** — the live SHA differs; show both the recorded SHA and
  the live SHA so the user can see how far behind it is.
- **never been probed** — `last_checked_sha` is null; this source has
  no prior probe on record, reported distinctly rather than compared
  against an absent value.
- **error** — the probe itself failed (unreachable remote, no such branch); shown inline with the diagnostic. One source's error does not stop the remaining in-scope sources from being probed and reported.

With zero in-scope `git-managed` sources, print `Nothing to probe.`
rather than no output.

`--probe` does not write `source-paths.json` — `lifecycle.last_checked_sha`
and `lifecycle.last_checked` are unchanged by this command. It does not
modify anything; it only reports. Persisting a probe result is REFRESH's
job, not this one's.

## Invariants

STATUS is read-only. It surfaces findings; it does not propose edits, does not
fetch upstream, and does not modify `research/.research-state.json`. The
underlying state read uses a pre-render guard so the dashboard never blocks on
a partial write. The Cache section is read-only too: STATUS reports cache
state but never deletes from it.
