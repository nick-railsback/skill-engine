---
name: review
description: Use when DISCOVER or REFRESH has surfaced a proposal staged at <name>-context.proposed/, to inspect it and record sign-off before applying it.
---

# Review

A pending proposal lives at `<install>/<name>-context.proposed/`. This skill inspects that staging directory without mutating either it or the live contextualizer at `<install>/<name>-context/`. The user's review is what teaches the engine what "good" means for this source — `review` is the surface that loads the question, not a rubber stamp on a pre-committed artifact.

## When to invoke

Invoke `/skill-engine:review <name>` after DISCOVER or REFRESH has surfaced a "Proposal staged at `<name>-context.proposed/`" line in its post-run summary. The skill runs in two passes against the same proposal: the first pass prints the manifest, the configured diff command, and the path to `REVIEW.md`; the second pass (after the user fills Step 1 of `REVIEW.md`) re-reads the file, generates the Step 2 disagreement set, and rewrites that section in place.

## Resolving `<name>`

The `<name>` argument is the contextualizer slug *without* the `-context` suffix. `/skill-engine:review vitejs-vite` operates on `<install>/vitejs-vite-context.proposed/`.

Bare invocation (no argument) works when exactly one `*-context.proposed/` directory exists under `<install>`. When zero match, surface `no proposed staging dir found under <install>` and exit cleanly. When two or more match, surface the list and ask which one (mirrors the resolution order in `discover/references/staging-and-contextualizer-model.md` § Selecting a contextualizer).

Resolve `<install>` from the live contextualizer location. The proposed directory always sits as a sibling of the live `<name>-context/` directory. Run the script in [`shared/locator-block.md`](../../shared/locator-block.md) to resolve the live contextualizer root; `<install>` is that root's parent directory. This skill carries no root set of its own — that script is the engine's one definition of where a contextualizer can be installed, and it decides which match wins.

## First pass — manifest and diff command

When `REVIEW.md` exists but Step 1 still contains the literal `___` blanks (i.e., the user has not yet filled their predictions), do the following in order:

1. **Read the manifest.** Parse `<install>/<name>-context.proposed/.review/manifest.json`. The schema is documented in `discover/references/staging-and-contextualizer-model.md` § Staging directory; the relevant fields here are `entries[].path` and `entries[].status` (`added` / `modified` / `removed` / `unchanged`).

2. **Print the summary.** Render one paragraph per status bucket. Group `added`, `modified`, and `removed` entries by status; omit `unchanged` from the print (it is recorded in the manifest for `apply` to consume but is not interesting to a reviewer). One line per file, prefixed with the status verb:

   ```
   Added (N):
     - <path>
   Modified (M):
     - <path>
   Removed (K):
     - <path>
   ```

   Empty buckets are omitted, not surfaced as "Added (0):".

3. **Print the diff command.** Read the configured `diff.tool` value from `$CLAUDE_PLUGIN_DATA/config.json`. If the file is absent, or the key is absent, or `$CLAUDE_PLUGIN_DATA` is unset, fall back to the default: `git diff --no-index --color`.

   Print one line naming the command and the two paths to diff:

   ```
   To inspect the diff, run:
     <diff-command> <install>/<name>-context/ <install>/<name>-context.proposed/
   ```

   For first-run proposals where the live `<name>-context/` does not yet exist, substitute `/dev/null` for the live path so `git diff --no-index` still produces a meaningful one-sided diff.

4. **Open `REVIEW.md` or print its path.** The primary caller of this skill is a non-interactive Claude agent session in which `$EDITOR` is unset; the print-path branch is what fires in practice. Print the absolute path plus a one-line instruction:

   ```
   Open <install>/<name>-context.proposed/.review/REVIEW.md in your editor, fill Step 1, save, then re-run /skill-engine:review <name>.
   ```

   The secondary `$EDITOR`-set branch is a convenience for a human running the command directly in a terminal: when `$EDITOR` is set, spawn `$EDITOR <path-to-REVIEW.md>` and wait. Either branch leaves the user at the same edit-loop: fill Step 1, save, re-run.

## Second pass — populate Step 2

When `REVIEW.md` exists and the three Step-1 lines no longer contain the literal `___` substring (heuristic: search each of the three prediction lines for the substring `___`; if all three are absent, Step 1 is filled), do the following:

1. **Re-read `REVIEW.md`** and the proposed tree.

2. **Compute the disagreement set** between the user's predictions and the proposed contextualizer's coverage.

   **How many to ask for.** The budget is a function of the proposal's *counted entries* — the `.review/manifest.json` entries whose `status` is `added`, `modified` or `removed`. `unchanged` entries record how big the contextualizer is, not how big this proposal is, so they are excluded from the count, the same omission the first pass already makes when it prints the status buckets. A three-file refresh of a 200-reference contextualizer is a small review.

   | counted entries | disagreements |
   |---|---|
   | ≤ 40 | 5–9 |
   | 41–80 | 7–11 |
   | 81–120 | 9–13 |
   | each further 40 begun | both bounds rise by 2 |
   | 321 or more | 21–25 |

   Both bounds rise together, so the window stays four wide at every proposal size, and both stop at the cap of 25 — the largest proposals ask for 21–25 and never more, because a fixed quota on a 5,000-file proposal is a recipe for padding. Read the pair off the manifest in front of you rather than reciting one: run the block below with the proposed tree's `.review/manifest.json` as its only argument and it writes the lower and upper bound, space-separated, on one line. A non-zero exit means the manifest could not be counted — say so and stop, rather than proceeding on a window it did not give you. A budget that silently stops tracking the proposal's size is worse than no budget, because it still looks like one.

```budget-rule
# Disagreement budget for one proposal, read off its own manifest.
#   usage: bash <this block> <manifest.json>   ->   "<lower> <upper>"
#
# `set -e` as well as `set -u`. Without it a failing python3 left `n`
# empty, bash arithmetic read the empty operand as 0, and the block
# printed "5 9" and exited 0 — the floor, and indistinguishable from a
# legitimately small proposal. A 5,000-entry proposal whose manifest was
# unreadable would then be reviewed at the smallest budget with nothing in
# the output saying the count had failed, which is the opposite of what a
# size-aware budget is for. A manifest that cannot be counted has no
# budget: say so, and stop.
set -eu
n="$(python3 - "$1" <<'PY'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        entries = json.load(fh)["entries"]
except (OSError, ValueError, KeyError, TypeError) as exc:
    sys.stderr.write(
        "cannot count %s: %s. The disagreement budget is a function of this "
        "manifest's counted entries; without one there is no budget to "
        "read.\n" % (sys.argv[1], exc)
    )
    sys.exit(65)
print(sum(1 for e in entries
          if e.get("status") in ("added", "modified", "removed")))
PY
)"
k=$(( n > 40 ? (n - 1) / 40 : 0 ))
# `|| ceiling`, not `&& ceiling`: under errexit an `[ … ] && x=y` list whose
# test is false returns 1 and takes the whole block down with it.
lower=$(( 5 + 2 * k )); [ "$lower" -le 21 ] || lower=21
upper=$(( 9 + 2 * k )); [ "$upper" -le 25 ] || upper=25
printf '%s %s\n' "$lower" "$upper"
```

   **Rank by magnitude:**
   - **Scope-mismatch disagreements** rank highest: the prediction's "for ___" or "NOT ___" boundary differs from the navigator's actual coverage (e.g., user says "this skill is for the runtime API only" but the proposal includes plugin-authoring references).
   - **Content-style disagreements** rank next: prose voice, reference partition shape, depth-of-detail choices.
   - **Reference-count disagreements** rank lowest: number of references emitted, whether a borderline candidate became its own reference or got folded.

   **Group the set when the proposal spans more than one catalog section.** A counted entry's group is the navigator section whose catalog row cites the reference that entry belongs to — either a plain source section, headed `## Catalog: <source-slug>`, or a slice section, headed `## Catalog: <source-slug>/<slice-id>`. *Belongs to*, not *is*: for a directory-form reference the catalog row's target is `references/<slug>/` while the manifest names `references/<slug>/<slug>.md` and each of its assets separately, so both sides reduce to the reference identity `verify.sh` Check 4 uses — the slug without `.md` and without a trailing `/` — before they are compared. Resolve `added` and `modified` entries against the *proposed* navigator. Resolve `removed` entries against the **live navigator** at `<install>/<name>-context/SKILL.md`: a reference is removed precisely because the proposed catalog stopped citing it, so no proposed row can name one, and the live navigator is the only place a purge of thirty references can still be attributed from. Counted entries no catalog row cites — anything under `research/`, the navigator itself — collect into one residual group named `Unattributed`, which is rendered when grouping is already in force and never triggers grouping on its own; a single-section proposal with a residual stays a flat list. When more than one *named* group is present, write the disagreements under one sub-heading per group, each heading carrying that group's counted-entry count, ranked within the group. When only one named group is present, keep today's single flat ranked list. The block below reports the verdict and the per-group counts: it prints `flat` or `grouped` on its first line, then one line per group — the group's name, a tab, its counted-entry count.

```group-rule
# Which catalog sections a proposal's counted entries fall into.
#   usage: bash <this block> <manifest.json> <proposed-navigator> <live-navigator>
set -u
python3 - "$1" "$2" "$3" <<'PY'
import json, re, sys

SECTION = re.compile(r"^#{2,3}\s+Catalog:\s*(\S+)\s*$")
LINK = re.compile(r"\]\(([^)]+)\)")
RESIDUAL = "Unattributed"
PREFIX = "references/"


def reference_id(path):
    """The reference a path belongs to, or None when it belongs to none.

    Both sides of the lookup have to be reduced to this before they can be
    compared: a catalog row names a reference, a manifest entry names a
    file, and for the directory form those are never the same string.

        catalog row target   references/billing-refunds/
        manifest entry path  references/billing-refunds/billing-refunds.md
        its assets           references/billing-refunds/flow.svg, ...

    The rule is verify.sh Check 4's, which defines a reference's identity
    as the slug without `.md` and without a trailing `/`; every file under
    a directory-form reference belongs to that reference. Anything else --
    `research/...`, the navigator itself, a malformed target carrying
    neither suffix -- has no reference and falls to the residual.
    """
    path = (path or "").strip()
    if not path.startswith(PREFIX):
        return None
    rest = path[len(PREFIX):]
    head, slash, _ = rest.partition("/")
    if slash:
        return head or None
    return rest[:-3] if rest.endswith(".md") else None


def catalog_of(navigator):
    """Map each cited reference to the catalog section citing it."""
    cited, section = {}, None
    try:
        with open(navigator, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return cited
    for line in lines:
        found = SECTION.match(line)
        if found:
            section = found.group(1)
            continue
        if line.startswith("#"):
            section = None
            continue
        if section:
            for target in LINK.findall(line):
                ref = reference_id(target)
                if ref is not None:
                    cited.setdefault(ref, section)
    return cited


manifest, proposed, live = sys.argv[1], sys.argv[2], sys.argv[3]
from_proposed, from_live = catalog_of(proposed), catalog_of(live)

with open(manifest, encoding="utf-8") as fh:
    entries = json.load(fh)["entries"]

counts, named = {}, set()
for entry in entries:
    status = entry.get("status")
    if status not in ("added", "modified", "removed"):
        continue
    lookup = from_live if status == "removed" else from_proposed
    ref = reference_id(entry.get("path"))
    group = RESIDUAL if ref is None else lookup.get(ref, RESIDUAL)
    counts[group] = counts.get(group, 0) + 1
    if group != RESIDUAL:
        named.add(group)

print("grouped" if len(named) > 1 else "flat")
for group in sorted(counts):
    print("%s\t%d" % (group, counts[group]))
PY
```

   **Name who signs.** When `source-paths.json` records an `owner` at the document root, name that owner in the Step 2 preamble as the person whose sign-off the proposal is waiting on. `owner` is a document-root key describing the whole contextualizer, not a per-source one, so a proposal never has two. When the key is absent, say nothing — an unrecorded owner is not a finding.

3. **Write the disagreement set** between the existing Step 2 section markers, leaving Steps 1 and 3 byte-for-byte unchanged. Immediately below the `## Step 2 — Disagreement set` heading and above the ranked bullet list, first check for hand-edited references: run `python3 "$CLAUDE_PLUGIN_ROOT/tests/hand_edit_check.py" <install>/<name>-context.proposed/.review/manifest.json <install>/<name>-context/.review/manifest.json` and parse the JSON array it writes to stdout. This is independent of, and computed separately from, the disagreement set below — like the density line that follows it, it is report-only, never itself a disagreement, and never counted toward the slot budget, so a hand-edited file is never at risk of ranking out of the surfaced set the way a low-magnitude disagreement can. For each flagged entry, write one line: `Hand-edited since last promotion: <path> (engine last wrote <live_sha_after>; this proposal's baseline was <proposal_sha_before>).` When the array is empty, the absence of a mismatch is silent: write nothing, not a printed "no hand edits found" line — matching the same empty-bucket convention the first pass's Added/Modified/Removed lists already use. Then write one line stating the paragraph→permalink density this run computed against the proposed tree: run `python3 "$CLAUDE_PLUGIN_ROOT/tests/permalink_density.py" <install>/<name>-context.proposed/references` and parse its `[PASS]`/`[FAIL]` percentage, then write `Paragraph→permalink density: <pct>% (report-only; not one of the disagreements below).` Immediately below it, write `Re-emit candidates: N of M references cite changed paths (K changed paths uncited).` — never counted toward the slot budget, and omitted entirely when no source advanced this run. Compute it by running `python3 "$CLAUDE_PLUGIN_ROOT/tests/cited_paths.py" <install>/<name>-context.proposed/references --changed <install>/<name>-context/research/.discover-inventory.json`: N is the count of references present under `.candidates`, M is the proposed tree's total `*.md` count, K is `.uncited_changes.count`; when `<install>/<name>-context/research/.discover-inventory.json` is absent or carries no source's `since_last_check` (no source advanced), skip the line. Immediately below it, for each source that advanced, write `Re-pinned: <repinned> of <citations> citations moved mechanically; <needs_review> read by hand.` — the counts REFRESH's post-run summary reported from `repin_citations.py` (`refresh/references/drift-detection-and-phases.md` § Re-read scoping); recompute them if that summary is not at hand by running `python3 "$CLAUDE_PLUGIN_ROOT/tests/repin_citations.py" <install>/<name>-context/references --repo <the source's cache directory> --old-sha <live last_checked_sha> --new-sha <proposed last_checked_sha>` with no `--out-dir`, which is a dry report. Omit the line when no source advanced. A proposal whose re-pin read nothing by hand and whose re-read rewrote no sentence has an empty disagreement set by construction — the only substance is the pin — and the *"Only <N> disagreement<s?> surfaced"* line below is the right rendering of it, not a sign the pass was skipped. This, the density line and the candidates line are independent of, and computed separately from, the disagreement set below — report-only, never themselves a disagreement. Then write the disagreements. Each disagreement is one sentence with verdict checkboxes:

   ```
   - [ ] accept  [ ] reject   <one-sentence disagreement>
   ```

   If fewer than the budget's lower bound exist (a tightly-aligned proposal), surface what there is and add a trailing italic line: *"Only <N> disagreement<s?> surfaced — this proposal aligns closely with your predictions."* If more than the upper bound exist, take the top <upper> by magnitude and add a trailing italic line: *"<K> additional disagreement<s?> not shown."*

4. **Save the file** with Steps 1 and 3 preserved exactly as the user left them. Do not auto-tick any verdict box; the user does that.

5. **Print a one-line confirmation** naming the file path and the disagreement count.

## Edge cases

- **Manifest missing.** A proposed directory that lacks `.review/manifest.json` is incomplete — DISCOVER or REFRESH did not finish. Surface a diagnostic naming the proposed dir, suggest `/skill-engine:discard <name>` to remove the half-written staging tree, then exit non-zero.

- **`REVIEW.md` missing but manifest present.** Stamp the `REVIEW.md.template` body (with `<name>` substituted) into `<install>/<name>-context.proposed/.review/REVIEW.md`, then continue with the first pass. This makes the skill self-healing for proposed dirs whose template stamp was interrupted.

- **Step 1 filled but Step 2 already populated.** The user has filled their predictions, the engine has populated Step 2, and the user is invoking `review` again. Treat this as "user wants a refresh of Step 2" — recompute the disagreement set against the current proposed tree (which may have advanced if a REFRESH ran in between) and rewrite Step 2 in place.

- **Step 3 already ticked.** The user has signed off but is re-running `review` to inspect the manifest or diff before `apply`. Do not regenerate Step 2; just run the first-pass manifest/diff print.

## What this skill does NOT do

- It does not promote the proposed dir to the live tree. That is `/skill-engine:apply`'s job.
- It does not remove the proposed dir. That is `/skill-engine:discard`'s job.
- It does not invoke `git diff` itself; it prints the command for the user to run. The user's diff tool may not be `git` at all — `delta`, `kdiff3`, or any other configured command is the user's choice.
- It does not validate the diff output for content correctness; the disagreement set in Step 2 is the engine's read, not a lint.
- It does not auto-tick Step 3. Sign-off is an explicit user gesture.
