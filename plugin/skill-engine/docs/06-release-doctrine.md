# 06-Release doctrine

This chapter covers two related concerns: how the artifact gets released, and the load-bearing design stances that govern the engine. Releases are mechanics — a checklist, a CHANGELOG convention, the destructive-gate awareness. The doctrine is philosophy — what the engine deliberately doesn't do, and why. Skipping the doctrine is how contextualizer engines drift into auto-merging crawlers and lose the human-in-the-loop guarantees that made the pattern worth building in the first place.

## Release process

> **Scope note — CLI steps are the optional pattern.** The public `skill-engine` engine carries its version in **one** surface (`.claude-plugin/plugin.json`) and distributes through the plugin marketplace and the Claude Desktop zip (the manual `zip` in [04-delivery.md](04-delivery.md#surface-3-desktop-zip)). The CLI-specific steps below — the `# Version:` / `VERSION=` surfaces and the `bin/<area-domain>-context package` artifact build — belong to the **optional CLI pattern** a builder may adopt (see [04-delivery.md](04-delivery.md#surface-1-cli-installer-optional-pattern)), not to something the engine generates. Where a step says "all N surfaces," read it as "`plugin.json`, plus the CLI / test surfaces only if you adopted that pattern."

### Semantic versioning, applied to a contextualizer

Standard MAJOR.MINOR.PATCH, but adapted to what changes in a contextualizer mean:

| Version bump | When |
|---|---|
| **MAJOR** (e.g., 1.0.0 -> 2.0.0) | Breaking change to the install layout, the metadata schema, or the navigator structure. Triggers a legacy-upgrade flow on existing installs. |
| **MINOR** (e.g., 1.0.0 -> 1.1.0) | New reference file added to the catalog, a new engine workflow (or a new CLI feature, under the optional CLI pattern). |
| **PATCH** (e.g., 1.0.0 -> 1.0.1) | Reference content updates, bug fixes, doc fixes that change what users see after running update. |

**A subtle case: what about internal changes that don't affect users?** Engine refactors, tooling tweaks, doc-only updates to the contextualizer itself (not the references it ships). Those go into `[Unreleased]` (see CHANGELOG conventions below) and roll into the next release - not a separate patch bump.

### Release checklist

Eight steps, in order. Most are scriptable; treat the whole thing as a manual checklist for the first dozen releases until the muscle memory is reliable, then automate selectively.

1. **Decide the version.** Pick MAJOR/MINOR/PATCH from the table above. If unclear, ask: "what would surprise a user about this update?" Surprise = bigger bump.
2. **Bump the version** (see [04-delivery.md#4-place-version-sync](04-delivery.md)):
   * `.claude-plugin/plugin.json` `"version": "X.Y.Z"` — **always** (the engine's one version surface)
   * CLI script header comment: `# Version: X.Y.Z` — *optional CLI pattern only*
   * CLI script `VERSION="X.Y.Z"` variable — *optional CLI pattern only*
   * (fixture-harness planned: a `verify.sh` version-consistency check would add a further surface.)
3. **Update CHANGELOG.md.** Move any `[Unreleased]` entries under a new `[X.Y.Z] - YYYY-MM-DD` header. Add new entries for any release-only changes.
4. **Run the validator.** `./verify.sh` must pass with `Failed: 0`. Version-consistency belongs to the fixture-harness milestone; until then, eyeball-review the diff in step 5 to catch a missed bump.
5. **Commit and push the version bump.** One commit, message like `chore(release): vX.Y.Z`. Push to your default branch.
6. **Build the release artifacts.** The Desktop zip is the engine-supported artifact — build it with the manual `zip` from [04-delivery.md](04-delivery.md#surface-3-desktop-zip) (top-level entry = the skill folder). If you adopted the optional CLI pattern, `bin/<area-domain>-context package` automates the same zip:
   ```bash
   # optional CLI pattern:
   bin/<area-domain>-context package
   # produces <area-domain>-context-vX.Y.Z.zip and <area-domain>-context.zip (stable name)
   ```
7. **Create the release on your git host.** (e.g., GitHub or GitHub Enterprise):
   ```bash
   gh release create vX.Y.Z \
     <area-domain>-context-vX.Y.Z.zip \
     <area-domain>-context.zip \
     --notes "See CHANGELOG.md for details"
   ```
   Both zips must be uploaded - versioned for provenance, stable-named for the permanent download URL.
8. **(If applicable) Plugin marketplace sync.** If you publish to a marketplace, push the tag and let the marketplace re-crawl the new `plugin.json` version. Some marketplaces require a separate sync action.
9. **(Optional) Notify stakeholders.** Internal Slack channel, mailing list, etc. Skip if your update cadence is high enough that announcements would be noise.

### Destructive gates

Two steps in the checklist are destructive - meaning hard to reverse if you do them wrong:
* **Step 5 (commit and push):** The user can review the diff before pushing. Don't skip the review even on releases.
* **Step 7 (`gh release create`):** Creates a tag and a release on your git host. Tags are removable but reflect badly in the release timeline; releases can be deleted but downloaded zips can't be unsent.

Treat these as manual approval gates. Do not chain them into a single automated script that runs end-to-end without pauses. The five seconds you save by automating is dwarfed by the hour you'll spend cleaning up a misfired tag.

## Encoding the release ritual as a slash command (Claude Code)

**Why bother.** The first few times you cut a release you'll forget at least one of the four version-sync surfaces, mistype a `gh release create` flag, or upload only the versioned zip and break the stable-name URL. A guided command catches each of these because the steps are written down once and run by the model every time. By release ten or twenty, you'll have internalized the checklist - but the new maintainer who picks this up after you has not. The slash command is for them.

**What to encode in the command.** A reasonable shape mirrors the source pattern's 10 phases (numbered slightly differently from the 8-step checklist above to make sub-steps explicit). Slash commands are a first-class Claude Code primitive - markdown files in `.claude/commands/` that the runtime reads as guided procedures.

1. **Preflight** - tools present, host CLI authed, working tree clean, current branch noted, tests pass
2. **Version resolution** - read current VERSION, compute next, display current -> new, pause for confirmation
3. **Bump the version surfaces** - `plugin.json` always; the CLI header, CLI variable, and test assertion only if you adopted the optional CLI pattern
4. **Draft the CHANGELOG entry** - collect commits since last tag, render in your house style, pause for human edit
5. **Re-run tests** - test version consistency is the gate that catches missed bumps
6. **Commit (destructive gate #1)** - single commit `chore(release): vX.Y.Z`, show the diff, pause before push
7. **Push to origin**
8. **Build the two zips** - versioned (`<area-domain>-context-vX.Y.Z.zip`) + stable-named copy (`<area-domain>-context.zip`)
9. **Create the host release (destructive gate #2)** - both zips uploaded, release notes from CHANGELOG, pause
10. **Verify and report** - print release URL, surface the marketplace-sync follow-up step (the cross-repo sync from "If your marketplace is a separate repo" in [04-delivery.md](04-delivery.md))

The **two destructive-gate pauses** (commit/push, then host release) are the load-bearing parts. They're where the human catches "wait, the CHANGELOG entry should say X, not Y" or "the new version is wrong." Do not collapse them into a single automated `/ship` button.

**A drop-in skeleton lives in the plugin's `engine-bootstrap-templates/` bundle** (find at `plugin/skill-engine/engine-bootstrap-templates/release-command.md.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/release-command.md.template>). Copy it to your repo's `.claude/commands/release.md`, swap the placeholders (`<area-domain>`, `<your-git-host>`, `<host-cli>`, etc.), and customize the org-specific bits in Phase 10.

**`.gitignore` caveat.** Many `.gitignore` defaults exclude `.claude/`. If yours does, allow `.claude/commands` through explicitly so the slash command travels with the repo for every maintainer who clones it. Deleting `.claude/commands/release.md` (or never committing it) silently removes `/release` from new maintainer environments - a quiet failure mode worth a one-line invariant in your repo's contributing notes.

## CHANGELOG conventions

### Format

```markdown
## [X.Y.Z] - YYYY-MM-DD
- type: concise description (path/area)
- type: another change description (path/area)
```

### Types are a fixed set

| Type | Meaning |
|---|---|
| `add` | New feature, new reference, new file |
| `change` | Modification to existing behavior |
| `fix` | Bug fix |
| `remove` | Deleted feature, deleted reference |
| `deprecate` | Marked for removal in a future version |

Use them consistently - they let readers scan the CHANGELOG for "what broke" vs. "what's new."

### Style

Each entry is one bullet, one sentence (occasionally two). Lead with the type. Include the file or area in parentheses. Focus on the *what* and the *why*, not the *how* - code lives in git, not the CHANGELOG.

```markdown
## [1.2.0] - 2026-04-20

- add: new primary reference for the billing pipeline (`references/<area-domain>-billing.md`). Catalog updated; checksums added.
- change: the engine adopts SHA comparison before clone in REFRESH and DISCOVER. 80% reduction in crawl time for steady-state cycles.
- fix: CLI auto-detection no longer prompts when env var is set (`bin/<area-domain>-context`).
```

### The [Unreleased] convention

Use a top-of-file `[Unreleased]` section for changes that ship internally to the contextualizer's repo but *don't* change what end-users see after running `<area-domain>-context update`:

```markdown
# CHANGELOG

## [Unreleased]
- change: engine refactor for circuit breaker thresholds. No user-visible effect.
- add: `skill-engine/docs/` domain-agnostic documentation set.

## [1.2.0] - 2026-04-20
...
```

When the next release happens (for any reason), the entries under `[Unreleased]` move under that release's version header. Don't create a separate patch release just to publish doc-only updates - bundle them with the next release that has a real reason to ship.

## Engine doctrine

The engine's design has two load-bearing stances that govern every other decision: a list of things the engine deliberately does *not* do, and a defense of why the maintenance cadence stays manual rather than scheduled. Both protect the property that makes a contextualizer trustworthy as ground truth — that no content reaches consumers without a human reading the diff first.

When you adapt these patterns, these are the two parts to leave intact. Almost everything else (catalog shape, reference budget, distribution surfaces, even the engine's internal workings) can be tuned to your domain. These cannot, without changing what the engine fundamentally is.

### Things the engine deliberately does NOT do

Each item below was considered as a feature and rejected for a specific reason. Before adding any of them, read the rationale and confirm the failure mode it prevents is one you're willing to take on.

* **CI for releases.** Release is manual because each release is a deliberate decision. CI would invite "ship it because it's green" thinking that's wrong for a content-as-source-of-truth project.
* **Cron/scheduled triggers for the engine.** Manual cadence is intentional. See "manual-cadence stance" below for full rationale.
* **Push notifications or alerts.** If the maintainer needs pinging, they check STATUS during their normal week, not as a reaction to alarm bells.
* **Per-user/per-project versioned channels.** One version stream. Users who want older releases re-install via git checkout.
* **Auto-merge for engine proposals.** All content changes require human approval. The cost of a bad crawl silently propagating to every consumer is much higher than the time spent reviewing diffs. (The opt-in SELF-AUDIT fix flow is not auto-merge — it requires an explicit `APPROVE` per session and pre-approval validation passes before any write.)

### CI-for-validation vs. CI-for-releases

The "no CI" stance above is specifically about *release CI* — a build server that decides when changes ship. There is a separate, narrower form — *validation CI*, which just runs the same checks the maintainer would run by hand — that the engine does support, opt-in.

`pre-commit.sh.template` (find at `plugin/skill-engine/engine-bootstrap-templates/pre-commit.sh.template`) is a small POSIX-bash wrapper around `bash verify.sh` (your consumer-stamped `verify.sh`; same script the contextualizer's release ritual runs). Installed as `.git/hooks/pre-commit` (manually, by the maintainer), it gates each commit on a green verify pass. This is a frictionless on-ramp to the same green-bar discipline the release ritual already asks for; it is not a substitute for the release gate, and it does not change the property that release decisions stay reviewer-driven. The hook is opt-in — the project does not auto-install it — and the maintainer can pass `--no-verify` past it for a rare, deliberate bypass.

The engine remains hostile to CI-for-releases for the reasons above. CI-for-validation is the bounded, reviewer-augmenting form of the same machinery.

### The manual-cadence stance

The engine runs only when a maintainer triggers it. Three reasons:

1. **Approval gate is content-integrity-critical.** A bad crawl pattern silently propagating to every consumer is a worse failure than slower maintenance. Manual triggering keeps a human in the loop on every change.
2. **Cadence is irregular.** Upstream activity varies week to week. A cron wastes runs in quiet weeks and misses bursts. Manual triggering matches the actual workload pattern.
3. **Single-maintainer ownership.** This pattern aligns with Anthropic's guidance on effective harnesses for long-running agents — humans *in* the loop, not *on the side*. (See [01-principles.md](01-principles.md) for the source citation.)

If you find yourself wanting to automate the cadence, ask first whether what you actually want is better STATUS visibility (so you remember to run REFRESH) without needing a cron to do it for you.

## Closing: shipping the artifact to other teams

If this guide helped you stand up a working contextualizer, the most useful next step is to publish it where its consumers can find it - your team's wiki, an internal Slack post with the CLI install command, an entry in your org's plugin marketplace. The contextualizer's value is realized when consumers stop re-explaining the domain to AI assistants every session.

Then maintain it. Run REFRESH weekly for the first month. Notice which references drift fastest; adjust cadence. Watch your test suite catch the regressions you didn't expect.

After three months, you'll know whether the patterns in this guide fit your domain or need adjustment - push back on the patterns where they don't fit, but think twice before relaxing the load-bearing ones (catalog bijection, frontmatter discipline, manual cadence, byte-equality fixture).

You're shipping a system that other engineers will lean on as ground truth. The discipline that protects them is the same discipline that protects future-you when this contextualizer is the one being maintained by someone else.

[Next (before shipping to production): 10-version-evolution.md - Version numbering, template compatibility, backward-compatibility windows, and migration paths for plugin ecosystem.](10-version-evolution.md)

Then (whenever you want to grow the reference corpus — first runs welcome): [08-discover-pipeline.md - the DISCOVER pipeline: corpus crawling, companion proposals, lifecycle handling, post-run summary contract.](08-discover-pipeline.md)

Or skip ahead to: [11-walkthrough.md - a concrete end-to-end walkthrough](11-walkthrough.md), then the plugin's [engine-bootstrap-templates/](https://github.com/nick-railsback/skill-engine/tree/main/plugin/skill-engine/engine-bootstrap-templates) bundle to start scaffolding.
