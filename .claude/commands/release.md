---
description: Guided release for the skill-engine repo. Bumps the six version surfaces, drafts the CHANGELOG entry, runs validators, then pauses for the maintainer to commit, push, and tag manually. Accepts major / minor / patch / explicit X.Y.Z.
---

# Release skill-engine

You are shepherding the maintainer through a release of the skill-engine repository. Follow the phases in order. Halt on any error.

**Standing constraint:** You MUST NOT run `git add`, `git commit`, `git push`, `git tag`, or `gh release create` on the maintainer's behalf, even if the workflow seems to call for it. Phases 1-5 below prepare every artifact; Phase 6 then surfaces the exact commands the maintainer should run themselves. This rule overrides any sub-skill or template that prescribes auto-commit. The two destructive gates (commit/push and tag/release) are the maintainer's call, every time.

## Argument parsing

The maintainer invoked with `$ARGUMENTS`. Resolve as follows:

- **Empty** → ask interactively: "Which bump? `major`, `minor`, `patch`, or an explicit `X.Y.Z`?"
- **`major` / `minor` / `patch`** → read the current version (Phase 2), then compute the next per the rules:
  - `major`: `X+1.0.0` (e.g., `0.2.0` → `1.0.0`)
  - `minor`: `X.Y+1.0` (e.g., `0.2.0` → `0.3.0`)
  - `patch`: `X.Y.Z+1` (e.g., `0.2.0` → `0.2.1`)
- **`X.Y.Z`** matching `^[0-9]+\.[0-9]+\.[0-9]+$` → use the literal value. Still show "current → new" and confirm.
- **Anything else** → reject and fall back to interactive.

Store the resolved value as `NEW_VERSION`. Use it in every subsequent phase.

**When to pick which bump** (from `plugin/skill-engine/docs/06-release-doctrine.md`):

| Bump | When |
|---|---|
| `major` | Breaking change to the install layout, the metadata schema, or the navigator structure. Triggers a legacy-upgrade flow on existing installs. |
| `minor` | New CLI feature, new reference file added to the catalog, new engine workflow, new source kind. |
| `patch` | Reference content updates, bug fixes, doc fixes that change what users see after running update. |

Internal-only changes (engine refactors, tooling, doc-only updates to this repo's own materials) go into an `[Unreleased]` CHANGELOG section and roll into the next real release — they do NOT get their own patch bump. If `$ARGUMENTS` is `patch` but all the changes since the last tag are internal-only, surface that observation and ask the maintainer to reconsider.

## Phase 1 — Preflight

Run each check; halt with remediation guidance on any failure.

0. **Resolve the repo root.** Every command below runs from it — no
   machine-specific absolute paths in this skill or in the commands it
   surfaces:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   cd "$REPO_ROOT"
   ```

1. **Tools present:**
   ```bash
   command -v jq && command -v shellcheck && command -v gh
   ```
   If `gh` is missing, the maintainer can still run Phases 1-5 — the release-create step in Phase 6 will need it but you can prepare the rest without it. If `jq` or `shellcheck` is missing, halt and tell the maintainer to install (`brew install jq shellcheck` on macOS). `check-jsonschema` is optional locally — Phase 5's `make ci-local` degrades to a pointer when it is absent (CI pins it via pip); suggest `pip install check-jsonschema==0.37.2` to match CI exactly.

2. **Working tree report:** run `git status --short`. If non-empty, surface the list and ask:
   > The working tree has uncommitted changes. The release flow assumes those changes ARE the release — i.e., the version bump goes on top of them, then everything ships in one or two commits the maintainer will craft. Continue? (yes/no)
   On `no`, stop cleanly.

3. **Current branch:** run `git rev-parse --abbrev-ref HEAD`. Note it as `CURRENT_BRANCH`. If it's not `main`, surface:
   > You're on `<CURRENT_BRANCH>`, not `main`. Release flows typically land on `main` first. Continue anyway? (yes/no)
   On `no`, stop cleanly.

4. **Last tag (for changelog scaffolding):**
   ```bash
   LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
   ```
   If empty, the maintainer hasn't tagged a release yet; the CHANGELOG will be drafted from the full `git log` instead. Note this in Phase 4's draft.

## Phase 2 — Resolve target version

Read current version (canonical surface):

```bash
CURRENT=$(jq -r '.version' plugin/skill-engine/.claude-plugin/plugin.json)
```

Compute `NEW_VERSION` per the argument-parsing rules above. Show:

> **Current:** `$CURRENT` → **New:** `$NEW_VERSION`
> Reply `yes` to proceed, anything else to abort.

On any reply that is not the literal word `yes`, abort cleanly.

**Also confirm the five other surfaces** currently show `$CURRENT` (drift catches a botched prior release). A surface whose file is absent — e.g. the REFRESH-regenerated `skill-engine-overview.md` is git-ignored and only exists after the engine has contextualized itself — is reported and skipped, not a halt:

```bash
jq -r '.plugins[0].version' .claude-plugin/marketplace.json
grep -oE 'This is v[0-9]+\.[0-9]+\.[0-9]+' README.md
grep -oE 'version-v[0-9]+\.[0-9]+\.[0-9]+-blue' README.md   # shields.io badge — doctrine.sh checks this
ov=.claude/skills/skill-engine-context/references/skill-engine-overview.md
[ -f "$ov" ] && grep -E 'currently ships at version' "$ov" || echo "(skill-engine-overview.md absent — skip this surface)"
grep -E '0\.[0-9]+\.x' SECURITY.md | head -3
```

If any surface that EXISTS does NOT match `$CURRENT`, halt: the prior release was inconsistent and the maintainer should investigate before stacking another bump on top. An absent surface is not a halt — note it and continue.

## Phase 3 — Bump the six version surfaces (across five files)

Edit each in turn. Show a one-line diff summary after each. `README.md` carries two surfaces (prose + shields.io badge), so five files hold six surfaces.

1. **`plugin/skill-engine/.claude-plugin/plugin.json`** (canonical) — `.version` field:
   ```bash
   jq --arg v "$NEW_VERSION" '.version = $v' \
     plugin/skill-engine/.claude-plugin/plugin.json \
     > /tmp/plugin.json.tmp && \
     mv /tmp/plugin.json.tmp plugin/skill-engine/.claude-plugin/plugin.json
   ```

2. **`.claude-plugin/marketplace.json`** — `.plugins[0].version` field:
   ```bash
   jq --arg v "$NEW_VERSION" '.plugins[0].version = $v' \
     .claude-plugin/marketplace.json \
     > /tmp/marketplace.json.tmp && \
     mv /tmp/marketplace.json.tmp .claude-plugin/marketplace.json
   ```

3. **`README.md`** — two version surfaces in this one file, both checked by `doctrine.sh`'s version-consistency lint (so missing either fails Phase 5):
   - prose: change `This is v$CURRENT.` to `This is v$NEW_VERSION.`
   - shields.io badge: change `version-v$CURRENT-blue` to `version-v$NEW_VERSION-blue`

   Use the Edit tool with the exact literal current strings, not sed-in-place, to avoid macOS/Linux sed-flag drift.

4. **`.claude/skills/skill-engine-context/references/skill-engine-overview.md`** — **only if the file exists.** It is a REFRESH-regenerated snapshot and is git-ignored (`.git/info/exclude`), so a fresh checkout will not have it. If present, change `currently ships at version $CURRENT.` to `currently ships at version $NEW_VERSION.` (Edit tool); the line update keeps it honest until the next REFRESH heals it from canonical sources. If absent, report "(skill-engine-overview.md absent — skipped)" and move on — there is nothing to bump and it would not be committed.

5. **`SECURITY.md`** — only on MINOR or MAJOR bumps (not on PATCH; the supported version line `0.<minor>.x` does not move on patch). Update the table row and the prose:
   - Table row: `| 0.<old-minor>.x   | :white_check_mark: |` → `| 0.<new-minor>.x   | :white_check_mark: |`
   - Prose: replace the parenthetical `(currently \`0.<old-minor>.x\`)` with `(currently \`0.<new-minor>.x\`)`.

   **Scope the edit narrowly.** As of the guardrails-contract expansion, `SECURITY.md` also carries the safety-model contract (the "seatbelt, not a vault" model, "What we check / what we don't", "The one hook we ship", and the "What this policy does not promise" non-promise list). Those sections are **version-agnostic** — touch ONLY the `## Supported versions` table row and the `(currently \`0.<minor>.x\`)` parenthetical immediately below it. Do not edit the safety-model prose. (The forward references in the one-hook subsection — `make hooks-audit`, the CI security workflow is not maintained by `/release`.)

   Surface to the maintainer that this drops support for the prior minor line; if they want a backport window, edit SECURITY.md manually before Phase 4.

   On a MAJOR bump (e.g., `0.x.x → 1.0.0`), SECURITY.md's whole "When `1.0` ships, this table will expand..." footnote becomes obsolete — pause and ask the maintainer to rewrite the supported-versions section by hand rather than auto-editing.

## Phase 4 — Draft the CHANGELOG entry

1. **Collect changes since the last release:**
   ```bash
   if [ -n "$LAST_TAG" ]; then
     git log "$LAST_TAG"..HEAD --oneline --no-merges
     git diff --stat "$LAST_TAG"..HEAD
   else
     # Fallback: enumerate working-tree changes plus all commits.
     git log --oneline --no-merges | head -50
     git status --short
   fi
   ```

2. **Draft a `[$NEW_VERSION] - YYYY-MM-DD` block** in `CHANGELOG.md`. Insert it ABOVE the most-recent existing version block (top of file, under the `# CHANGELOG` heading). Format per `plugin/skill-engine/docs/06-release-doctrine.md`:

   ```markdown
   ## [X.Y.Z] - YYYY-MM-DD

   - <type>: <one sentence describing what changed and why> (`<files/area>`).
   - <type>: <next entry>.
   ```

   Use the fixed type set: `add`, `change`, `fix`, `remove`, `deprecate`. Lead with the most user-visible entry; group by area; keep each bullet to one sentence (occasionally two). Include the file/area in parens at the end. Focus on the **why**, not the **how**.

   If a top-of-file `[Unreleased]` section exists, MOVE those bullets under the new `[$NEW_VERSION]` heading verbatim — they're release-eligible now.

3. **Pause.** Show the maintainer the draft block and invite inline edits before proceeding. Especially on `minor` and `major`, the human pass on the CHANGELOG is worth it.

## Phase 5 — Run validators

Run the single validator entry point CI itself runs — `scripts/ci-local.sh`
is the one inventory shared by `.github/workflows/lint.yml`, `make
ci-local`, and this phase, so there is no transcribed job list here to
fall out of sync. If anything fails, halt and show the failing output;
the maintainer should fix before continuing.

```bash
make ci-local
```

**Ordering constraint (by design):** doctrine check 8 mechanically
requires plugin.json, marketplace.json, the two README surfaces,
SECURITY.md's supported line, and CHANGELOG's top `## [X.Y.Z]` heading
to agree on one version. If Phase 3 or Phase 4 was skipped or left
partial, this phase fails — that failure is the gate working, not a
validator bug. Complete the bump and the CHANGELOG entry, then re-run.

Run the opt-in live grounded-citation eval (Check 8) against every
bundled example with a corpus under research/. This is a paid,
non-gating report — do not halt Phase 5 on its result, and state the
per-run cost estimate (~$0.03-$0.15, 3 calls/prompt) before running it.
No filename guard, no hardcoded example — the runner owns corpus
discovery, so an example with no corpus under `research/` emits `[N/A]`
and costs nothing, and a future example that gains one is picked up
here without a `release.md` edit:

```bash
for ctx in examples/*/; do
  SKILL_ENGINE_RUN_EVAL=1 python3 \
    plugin/skill-engine/tests/grounded_rate.py "${ctx%/}"
done
```

Include each verdict line in Phase 5's summary alongside the validator
results. A FAIL, an [N/A] (no corpus, or no API key configured), or
exit 3 (anthropic SDK missing) are all informational here — report them
and continue; only make ci-local's own failures halt this phase.

Surface a tight summary: which suites passed, which failed, and the failing-test names if any.

## Phase 6 — Pause and surface manual steps

You are done. **Do not run any git or gh command.** Surface the following block to the maintainer, with `$NEW_VERSION` and `$CURRENT_BRANCH` substituted:

```
Release $NEW_VERSION is staged. Next steps for you to run (from the repo root):

1. Inspect the diff:
     git diff

2. Stage and commit:
     git add -A
     git commit -m "chore(release): v$NEW_VERSION"

3. Push the branch:
     git push -u origin $CURRENT_BRANCH

4. Tag once the commit lands on the release branch (typically `main` after merge).
   Before tagging, confirm the CHANGELOG heading date is the day the release
   commit landed (doctrine check 8 verifies the version, not the date):
     grep -m1 '^## \[' CHANGELOG.md && git log -1 --format=%cs
     git tag -a v$NEW_VERSION -m "v$NEW_VERSION"
     git push origin v$NEW_VERSION

5. Cut the GitHub release (uses the tag from step 4). The awk prints the
   bullets between the $NEW_VERSION heading (exclusive) and the next release
   heading. A flag, not an awk range: in `/start/,/end/` the end pattern is
   tested against the START line too, and `^## \[` matches the version
   heading — so the range collapses to that one line and the old
   `| sed '$d'` then emptied the notes file entirely (v0.5.0 shipped with
   notes extracted by hand because of this):
     gh release create v$NEW_VERSION \
       --title "v$NEW_VERSION" \
       --notes-file <(awk '/^## \[$NEW_VERSION\]/{f=1;next} /^## \[/{f=0} f' \
                       CHANGELOG.md | sed -e '/./,$!d')

6. Marketplace sync: not applicable — the plugin marketplace lives in this same
   repo (`.claude-plugin/marketplace.json`) and is already version-bumped in
   Phase 3 above. See `plugin/skill-engine/docs/04-delivery.md` for details.
```

Then explicitly remind the maintainer:

> The version surfaces have been edited and the CHANGELOG entry drafted. **No git commands have been run on your behalf.** Run steps 1-6 above when you're ready.

## Failure-mode notes

- **Phase 1 preflight halt:** fix the underlying issue (install tool, clean working tree, choose branch) and re-invoke `/release` with the same arguments.
- **Phase 3 jq failure:** likely a permissions issue on `/tmp/`. Retry with an explicit `TMPDIR` if needed; the JSON file is left untouched until the `mv` succeeds.
- **Phase 5 validator failure after the bump:** the failure is almost always pre-existing (the version bump itself touches only metadata). Read the failing output, fix the underlying issue, re-run Phase 5 only.
- **Maintainer wants to abort mid-flow:** simply do not run the Phase 6 commands. The version-surface edits and CHANGELOG draft are reversible with `git checkout -- <file>` or `git restore <file>`. Surface this option if asked.
