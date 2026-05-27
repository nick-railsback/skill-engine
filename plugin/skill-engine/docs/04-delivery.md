# 04-Delivery

A contextualizer that's only installable one way is a contextualizer that excludes some of its consumers.
This chapter covers the three delivery surfaces, the CLI machinery that powers them, the metadata contract that lets future versions know what's installed, and the version-sync discipline that keeps all surfaces in lockstep.

**Two-tier framing.** The contextualizer (this chapter's subject) sits inside the engine — the maintenance system described in [01-principles.md](01-principles.md#two-tier-architecture). The engine ships once; a contextualizer plugs into it per domain. Everything below assumes that frame.

## Scope decisions for a contextualizer

A contextualizer is shaped by two scope questions, decided before the first reference is written.

**Single-domain vs. multi-domain.** When the same reader will routinely cross domain lines — a new hire who needs product, leadership, infrastructure, and onboarding context in one place; a senior engineer working across product + ML + frontend — one navigator routing across multiple domains is the right call. The audience is heterogeneous and the cross-domain lookups are real, so colocating them inside one navigator matches the work. When the audience is siloed — domain teams that don't co-read, a hundred services with independent owners, federated organizations where knowledge stays inside its domain — domain-specific contextualizers are the right call. Each navigator is sharp for its audience and there's no synthetic intersection to maintain.

**Onboarding shape vs. reference shape.** Onboarding has narrative arc and progressive disclosure; you read it once, top to bottom. Reference has WHEN-style routing and 500-line caps; you load only the chunks the question demands. The two shapes don't mix well in one skill — the WHEN routing fights the narrative. If the audience needs both, ship two skills (one onboarding, one maintenance contextualizer) rather than mixing shapes.

**The architecture is scope-agnostic.** The engine's invariants and tools work identically at any of these scopes. The trade-off is reader experience, not contract compliance. Audience-fit — will the same reader load all of this? — is the load-bearing axis; pick scope to match audience first, then layer the engine on top.

For source-root topology — single-repo vs. multi-repo, monorepo workspace vs. sibling repositories — see [01-principles.md](01-principles.md#source-root-topology). Topology and scope are independent axes.

## The case for shipping all three surfaces - and not just the plugin marketplace

This falls out of [Issue #46594](https://github.com/anthropics/claude-code/issues/46594) (covered in [01-principles.md](01-principles.md)): plugin update is unreliable, so the CLI must remain the trustworthy primary path. Plugin marketplace is added convenience. Desktop zip is for users who don't have a terminal or who prefer the Desktop app's native skill UI.

## Three delivery surfaces

| Surface | Best for | Update story |
|---|---|---|
| **CLI installer** | Engineers who already work in a terminal; scripted/automated installs | `<area-domain>-context update` re-runs the install |
| **Plugin marketplace** | Engineers in Claude Code who want one-line install | `/plugin update` (with caveat that this is currently unreliable per Issue #46594) |
| **Desktop zip** | Claude Desktop users who don't have a terminal | Re-download zip, re-upload via Settings -> Capabilities -> Skills |

Each surface installs the same navigator + references content. The only differences are how the content gets onto the user's machine and where it lives once installed.

**npm as a future surface.** Because the artifact ships a CLI binary already, an npm package is a natural fourth surface: the `bin/<area-domain>-context` script becomes an npm `bin/` entry, `package.json` joins the version-sync surfaces alongside `plugin.json`, and `npm install -g <area-domain>-context` becomes an additional install path that fits into existing JavaScript/TypeScript developer workflows. This guide does not yet flesh out the npm-specific details (publish flow, version-tag conventions, dependency declarations), but the artifact contract is intentionally compatible with that path so adoption later doesn't require a rewrite.

## Surface 1: CLI installer

The CLI is a single bash (or your-language-of-choice) script that copies the `skills/<area-domain>-context/` directory tree from the repo into the user's `.claude/skills/` directory and writes a metadata file recording what was installed.

### Function index: organize the CLI by responsibility

The source project's CLI script is ~700 lines of bash. The first 50 lines are a function index that lets a future maintainer navigate the file:

```bash
# CLI Function Index
#
# UTILITY
# show_version()          Display version information
# show_help()             Display usage help text
#
# VALIDATION
# check_dependencies()    Validate required tools (jq, etc.)
#
# SKILL HANDLING
# discover_skills()       Find the skill in the source directory
# install_skills()        Copy skill tree to target AI directory
# list_skills()           Show installed and available skills
#
# METADATA
# create_metadata()       Write .<area-domain>-metadata.json
#
# LEGACY MIGRATION
# detect_legacy_installation()  Detect pre-current-version artifacts
# clean_legacy_artifacts()      Remove pre-current-version artifacts
#
# UTILITY COMMANDS
# package_release()       Build <area-domain>-context-VERSION.zip
# update_installation()   Re-install from source (refresh content)
# clean_installation()    Remove the skill and metadata
#
# MAIN
# parse_arguments()       CLI argument parsing and routing
# main()                  Script entry point
```

A function index isn't documentation overhead - it's the price of admission for a script that will be maintained by someone other than its original author. The index belongs at the top of the file. Keep it in sync.

**Soft cap on CLI complexity.** Set yourself a budget - the source project targets <1,500 lines (currently around 700). New features should justify the line count; the CLI is an install path, not a Swiss army knife. When you find yourself wanting a fancier feature, ask whether it belongs in the research agent, a slash command, or another tool. The narrower the CLI, the easier the legacy-upgrade work in the next major version.

### Install flow

The install command runs four steps in order. Each step has a single responsibility:

1.  **`detect_legacy_installation()`**
    * Look for metadata file from a previous version
    * Look for filesystem signatures of older layouts
    * Return: legacy version detected or "none"
2.  **`clean_legacy_artifacts()`** (skipped if no legacy)
    * Remove old per-skill directories (if applicable)
    * Remove old metadata
    * Print what was cleaned (transparency for the user)
3.  **`install_skills()`**
    * `rm -rf` the target `skills/<area-domain>-context/`
    * `cp -R` the source `skills/<area-domain>-context/` to target
4.  **`create_metadata()`**
    * Write `.<area-domain>-metadata.json` with current schema

Each step is idempotent - re-running install on an already-installed system produces the same result. This means `<area-domain>-context update` is just `<area-domain>-context install` under a different command name; no separate update path needed.

### Metadata file

The CLI writes a metadata file at the root of the Claude Code directory (`.claude/.<area-domain>-metadata.json`):

```json
{
  "tool": "claude",
  "version": "1.0.0",
  "installed_at": "2026-04-20T14:23:11Z",
  "skills": ["<area-domain>-context"],
  "reference_files": 12
}
```

**Field rationale:**
* `tool`: pinned to `"claude"` today; the field exists so future installers can target additional Claude surfaces without a schema migration.
* `version`: used by future-version installers to detect upgrade path.
* `installed_at`: diagnostic; useful for debugging and for "when did this skill enter my project?".
* `skills`: an array even though there's only one skill, because future versions might add more. The array shape lets you extend without a schema migration.
* `reference_files`: diagnostic count. Mismatches against actual file count signal a partial install.

Don't put per-reference checksums in the metadata file. Drift detection between installs is not the metadata's job - that's the byte-equality fixture from [05-invariants.md](05-invariants.md).

### Error codes

Define error codes as constants near the top of the script:

```bash
ERR_NO_AI_DIR=1       # No .claude/ found and unable to create one
ERR_INVALID_PROFILE=2 # (reserved for future profile-based variants)
ERR_MISSING_FILE=3    # Required source file not found
ERR_NO_JQ=4           # jq dependency missing
ERR_PERMISSION=5      # File-system permission denied
```

Document each in the `--help` output. Users hitting `exit 4` should know that's a missing dependency without having to read the source.

## Surface 2: Plugin marketplace

### `plugin.json`

A minimal plugin manifest at `.claude-plugin/plugin.json`:

```json
{
  "name": "<area-domain>-context",
  "version": "1.0.0",
  "description": "Installs <area-domain> system skills into AI assistants, providing on-demand context for <area-domain> development.",
  "author": {
    "name": "<your-team>"
  },
  "repository": "git@<your-git-host>:<your-org>/<area-domain>-contextualizer.git",
  "license": "UNLICENSED",
  "keywords": [
    "<area-domain>",
    "context",
    "skills"
  ]
}
```

**Notes:**
* `version`: must match the CLI's `VERSION` and the test suite's version assertion. See [4-place version sync](#4-place-version-sync) below.
* `name`: must match the skill name (`<area-domain>-context`); the plugin marketplace uses it for namespacing.
* `license`: `UNLICENSED` is the right choice if your contextualizer is internal-only. Changing it requires a real licensing decision (GPL? MIT? Apache?) - don't pick one casually.
* `keywords`: drive marketplace search. Include both your domain (`<area-domain>`, `<area-domain>-platform`) and capability terms (`skills`, `context`).

**Namespacing:** When a user installs your plugin in Claude Code, it's invoked as `/<plugin-name>:<skill-name>`. With the same name on both, that becomes `/<area-domain>-context:<area-domain>-context`. The duplicate looks redundant but is correct - it's the platform's namespace separator.

### If your marketplace is a separate repo (the common case)

In most orgs, the plugin marketplace doesn't auto-crawl every published plugin's source repo. It's its own curated repo (e.g., `<your-org>/<your-org>-marketplace`), and a maintainer must copy each new release's plugin contents into the marketplace before consumers running `/plugin update` will see the new version.

**This is the single most common silent-failure mode in this distribution shape.** You ship `<area-domain>-context` v1.0.0, ship v1.0.1 a week later, never update the marketplace repo, and consumers stay on v1.0.0 indefinitely with no error. They might not figure it out for weeks.

The sync, manually:
1.  Clone or pull the marketplace repo (e.g., `git clone git@<your-git-host>:<your-org>/<your-org>-marketplace.git`).
2.  Copy this release's plugin artifacts into the marketplace's `<area-domain>-context/` subdirectory, replacing what's there:
    * `.claude-plugin/plugin.json`
    * `CHANGELOG.md`
    * `CLAUDE.md` (if your repo ships one)
    * `README.md`
    * The entire `skills/<area-domain>-context/` tree
3.  Confirm the `version` field in `<your-org>-marketplace/<area-domain>-context/.claude-plugin/plugin.json` matches the new release version.
4.  Commit and push directly to `main` (or whatever your marketplace's release branch is).

**Automate it with a slash command.** Once you've done the manual sync twice, encode it as a user-level `.claude/commands/<your-org>-marketplace-sync.md` slash command that runs the copy -> commit -> push. The source pattern's `release-command.md.template` (find at `plugin/skill-engine/engine-bootstrap-templates/release-command.md.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/release-command.md.template>) is a model for the structure (preflight diff -> summary -> destructive-gate pause before push). Mention the sync command in your repo's contributing guide so successors find it.

Don't conflate the marketplace sync with the host release. The host release (Phase 9 of the release ritual) is a git tag + GitHub release page on *your* repo. The marketplace sync is a separate gesture against a *different* repo. Keep them as two phases; bundling them masks failures (e.g., the marketplace push fails for auth reasons but the host release already shipped, leaving consumers in an inconsistent state).

### Updates: working around Issue #46594

`/plugin update` is unreliable per [Issue #46594](https://github.com/anthropics/claude-code/issues/46594). For a clean update:

```
/plugin uninstall <area-domain>-context
/plugin install <area-domain>-context@<your-org>-marketplace
```

Document this in your repo's `README`. Don't let users assume `/plugin update` works just because it exists. Even if the update DID work mechanically, it would still pull from a stale marketplace if you forgot the cross-repo sync above - so the marketplace-sync discipline is the more load-bearing fix; the manual reinstall is the user-facing workaround.

## Surface 3: Desktop zip

Claude Desktop accepts zipped skill uploads via Settings -> Capabilities -> Skills. The zip needs a specific shape.

### package command

Add a package command to your CLI that produces the right zip:

```bash
package_release() {
  local source_dir="$SOURCE_ROOT/skills/<area-domain>-context"
  local zip_name="<area-domain>-context-v${VERSION}.zip"

  # Build from skills/ so the top-level entry inside the zip
  # is <area-domain>-context/. Desktop requires this.
  cd "$SOURCE_ROOT/skills"
  zip -rq "$zip_name" "<area-domain>-context" \
    -x "*.git/*" -x "*.DS_Store" -x "*.swp" -x "*.bak"
  mv "$zip_name" "$invoker_cwd/"

  echo "Built: $zip_name"
}
```

**The critical detail:** the top-level entry inside the zip is `<area-domain>-context/`, not `skills/<area-domain>-context/*`. Desktop's upload UI rejects nested-path zips. `cd skills && zip ... <area-domain>-context` produces the right shape; `zip ... skills/<area-domain>-context` does not.

The `-x` patterns exclude editor cruft and git internals. The test suite enforces this (the `package_release` zip should not contain `.DS_Store`, `.git`, etc. - see [05-invariants.md](05-invariants.md)).

### Two zips: versioned & stable

Build two artifacts:

```bash
<area-domain>-context-v1.0.0.zip  # versioned (canonical provenance)
<area-domain>-context.zip         # stable name (for /releases/latest/download/)
```

The stable-named zip is a copy, not a link - many download flows don't follow git host symlinks correctly. Re-copy on every release.

The point of the stable name is that your `README` can include a permanent download URL:

```markdown
[Download the latest zip](https://<your-git-host>/<your-org>/<repo>/releases/latest/download/<area-domain>-context.zip)
```

Users don't have to hunt for the right version. Anyone with the link gets the current release.

### Upload flow (what to document for users)

In your main repo's `README`, document the Desktop install flow:

1.  Download `<area-domain>-context.zip` from the latest release.
2.  In Claude Desktop: Settings -> Capabilities -> Skills -> "Go to Customize" -> Create skill -> Upload a skill.
3.  Select the downloaded zip.
4.  The skill is immediately available as `/<area-domain>-context`.

For updates: "Re-download the zip and re-upload via the same flow. Desktop replaces the prior version in place."

## Legacy upgrade flow (when you ship v2.0)

When you make a breaking layout change in a future version, you'll need to handle users upgrading from older installs. The pattern:

### Record what you install in metadata (the load-bearing precursor)

Cleanup-on-upgrade is only as safe as your record of what you installed. Make the metadata file the authoritative list of artifacts your CLI created - write each installed skill, agent, command, or other artifact as a structured field in the metadata at install time.

On upgrade, read the *prior* metadata, enumerate what you put there, and remove *only* those entries. Don't trust filesystem patterns alone.

Why this matters: a follower whose v1.0 install dropped a few specific files into `.claude/` and whose v2.0 cleanup uses `find -name "<area-domain>*"` will eventually clobber a name-colliding artifact that another tool created. Pattern-based cleanup is a *fallback* for installs that pre-date metadata recording, not the primary mechanism. Even your v1.0 metadata should record enough to make v2.0's cleanup precise.

For example, an installer that adds a navigator skill plus a couple of agents could record:

```json
{
  "tool": "claude",
  "version": "1.0.0",
  "skills": ["<area-domain>-context"],
  "agents": [
    {"name": "<area-domain>-frontend-dev", "path": "agents/<area-domain>-frontend-dev.md"},
    {"name": "<area-domain>-backend-dev", "path": "agents/<area-domain>-backend-dev.md"}
  ],
  "reference_files": 12
}
```

On upgrade, iterate `agents` and `skills` from the prior metadata file and remove each by exact path/name. Any user-created agent that happens to share a name (e.g., a hand-written `agents/frontend-dev.md` that doesn't match the prefix exactly) is preserved because it's not in your `agents` array. Test this - the source project's test suite has explicit fixtures verifying user-named agents survive a legacy upgrade.

### Detection: signature-driven first, version-driven second

Look for filesystem signatures of older layouts before trusting the metadata file. Some users will have hand-edited metadata, broken installs, or pre-version-1 installs without metadata at all.

```bash
detect_legacy_installation() {
  # Signature: filesystem layout from a previous version
  if [ -d ".claude/skills/<area-domain>-foo" ]; then
    echo "v0.x" # old per-topic-skill layout
    return
  fi

  # Version-driven fallback
  if [ -f ".claude/.<area-domain>-metadata.json" ]; then
    local v
    v=$(jq -r '.version // "unknown"' ".claude/.<area-domain>-metadata.json" 2>/dev/null)
    if [ "$v" != "$VERSION" ]; then
      echo "$v"
      return
    fi
  fi

  echo "none"
}
```

### Cleanup: scoped, not scorched-earth

When cleaning legacy artifacts, only remove files you own. Never blindly `rm -rf .claude/skills/*`. Users may have other skills installed by other tools.

**Primary path: metadata-driven enumeration.** Read the prior version's metadata and remove only the artifacts it lists. This is precise - a user-authored agent that shares a name prefix with one of yours is preserved because it's not in the prior metadata's `agents` array.

```bash
clean_legacy_artifacts() {
  local meta=".claude/.<area-domain>-metadata.json"
  
  # nothing to clean if no prior install
  [ ! -f "$meta" ] && return 

  # Remove each agent listed in prior metadata, by exact path
  while IFS= read -r path; do
    [ -n "$path" ] && [ -f ".claude/$path" ] && rm -f ".claude/$path"
  done < <(jq -r '.agents[]?.path // empty' "$meta")

  # Remove each skill directory listed in prior metadata, by exact name
  while IFS= read -r skill; do
    [ -n "$skill" ] && rm -rf ".claude/skills/$skill"
  done < <(jq -r '.skills[]? // empty' "$meta")

  rm -f "$meta"
}
```

**Fallback path: pattern-based cleanup.** Only use this when the prior metadata is missing, malformed, or pre-dates structured artifact recording (e.g., a v0.x install that wrote nothing to metadata). Document it as a fallback, not the primary mechanism.

```bash
clean_legacy_artifacts_fallback() {
  # Use only when metadata-driven cleanup is impossible.
  # Risk: a name-colliding user artifact gets clobbered.
  find ".claude/skills" -maxdepth 1 -type d -name "<area-domain>-*" \
    -not -name "<area-domain>-context" -exec rm -rf {} +
}
```

**Print what was cleaned.** Surface the cleanup to the user. Silent file deletion is the wrong default:

```bash
echo "Removed legacy artifacts:"
echo "  .claude/skills/<area-domain>-foo/"
echo "  .claude/skills/<area-domain>-bar/"
echo "  .claude/.<area-domain>-metadata.json (v0.x format)"
echo
```

## 4-place version sync

The version string lives in **four** places. They must stay in lockstep, or a user will see one version in the CLI and a different version in the navigator.

| File | Format |
|---|---|
| 1. CLI script (header comment) | `# Version: 1.0.0` |
| 2. CLI script (VERSION variable) | `VERSION="1.0.0"` |
| 3. `.claude-plugin/plugin.json` | `"version": "1.0.0"` |
| 4. Test suite version assertion | `assert_contains "$output" "1.0.0"` |

The test suite enforces this with a `test_version_consistency` check that reads all four locations and asserts they match. See [05-invariants.md](05-invariants.md).

When you bump the version, update all four in the same commit. The release process ([06-release-doctrine.md](06-release-doctrine.md)) has this as a checklist item.

## Cross-platform and permissions

The contextualizer's install path and ongoing maintenance run in two distinct environments — the user's terminal and the AI assistant's tool-call sandbox. Both have platform constraints; both have permission knobs.

### Platform tiers

| Tier | Platforms | Notes |
|---|---|---|
| **Tier 1** | macOS, Linux, WSL2 (Windows Subsystem for Linux 2) | Fully supported. The install scripts and engine workflows assume bash here. WSL2 is genuinely first-class on Windows in 2026 — most Windows developers running this contextualizer use WSL2 and get the same experience as macOS/Linux users. |
| **Tier 2** | Git Bash on native Windows | Best-effort. Most install-time bash patterns work; some test-suite glob behavior and POSIX-only flags may need workarounds. Treat issues as bugs to fix, not as platform exclusion. |
| **Not yet supported** | PowerShell on native Windows | The CLI and engine scripts use bash patterns that don't translate. PowerShell users should run the contextualizer under WSL2 or Git Bash. |

The reason native Windows shells aren't first-class is mechanical: the install scripts and `verify.sh` use bash idioms (process substitution, `set -euo pipefail`, BSD-vs-GNU-aware tooling) that PowerShell doesn't speak. WSL2 and Git Bash both expose a real bash; PowerShell does not, and a port would mean shipping two diverging script sets. Until there's a real demand signal, this engine keeps one bash-driven pipeline and routes PowerShell users to WSL2.

### Per-verb permissions

The engine's maintain-time workload — running the research agent, calling out to GitHub for `gh issue` / `gh pr view` / `gh repo view`, executing the test suite — needs explicit tool permissions in the user's `.claude/settings.json`. The shipping shape is per-verb: allow the narrow GitHub commands the engine actually needs, ask before running fragile patterns (e.g., `gh api` calls that can hit unintended endpoints), and deny the dangerous ones outright.

The per-verb shape looks like this — adapt to your repo's threat model and drop the relevant rows into your `.claude/settings.json` (project-local) or `~/.claude/settings.json` (user-global):

```json
{
  "permissions": {
    "allow": [
      "Bash(gh issue view:*)",
      "Bash(gh pr view:*)",
      "Bash(gh repo view:*)",
      "Read(${CLAUDE_PLUGIN_DATA}/**)",
      "Edit(.claude/skills/**)"
    ],
    "ask": [
      "Bash(gh api:*)"
    ],
    "deny": [
      "Bash(gh pr merge:*)",
      "Bash(git push --force*)"
    ]
  }
}
```

The `Read(${CLAUDE_PLUGIN_DATA}/**)` entry is what lets the engine's `SessionStart` hook hydrate state from the plugin-managed location (see "Hooks-vs-permissions interaction" below); without it the hook would surface a permission diagnostic on every session start.

The `Edit(.claude/skills/**)` entry suppresses the per-write prompt for the engine's in-project skill writes only — the stamping, promotion, and staging steps that land files under `.claude/skills/`. `Edit` is the umbrella file-edit verb: it covers `Write` and `NotebookEdit` too, so no separate `Write(.claude/skills/**)` row is needed. Critically, this is **prompt-suppression only**. It does *not* punch through a user-level `deny` on `.claude/**`, and it does *not* override an OS-level sandbox restriction — an `allow` cannot widen either layer. A user who denies or sandboxes `.claude/**` and then hits a blocked write should see the engine's sandbox-block diagnostic (see "When a `.claude/skills/**` write is blocked" below), which routes them to the narrow fix rather than the prompt.

The `deny` list is the load-bearing piece. It encodes the engine's release doctrine — no auto-merge, no daemons, no destructive force-push — as enforceable guardrails (see [06-release-doctrine.md](06-release-doctrine.md) for the underlying anti-recommendations). A user who installs this contextualizer without the deny list still gets a working engine, but loses the safety net the doctrine prescribes.

**Forward-rot note.** Claude Code's per-verb permission grammar evolves with each release. If a future release documents a different grammar form, re-validate your `.claude/settings.json` against the new shape before adoption.

### When a `.claude/skills/**` write is blocked

The `Edit(.claude/skills/**)` grant above suppresses the *prompt* for the engine's in-project skill writes, but it cannot widen a user's `deny` or sandbox. A hardened user — one who `deny`s `.claude/**`, or runs a tightened OS-level sandbox — will hit a hard block when the engine tries to stamp, promote, or stage files there. The engine's contract at that seam is to fail loudly and precisely, naming the path and the *narrow* remedy.

This is the canonical sandbox-block diagnostic. The three engine write surfaces — `engine-bootstrap` Step 3 stamping, `apply` Promotion, and `discover`/`refresh` staging into `<slug>-context.proposed/` — each cross-reference this section rather than restating it.

The engine is a set of markdown skills an agent follows, not compiled code, so "detection" here is an agent-followed behavior, not a registered exception handler. **When a write targeting a `.claude/skills/**` path is rejected, the writing skill instructs the agent to emit the diagnostic below and stop** — not silently retry, not silently skip the file. Two write modalities reach this seam, and the diagnostic covers both:

- **Tool-call write** — an `Edit` / `Write` / `NotebookEdit` the agent issues is rejected, by a permission `deny` or by the sandbox refusing the path.
- **Shell write** — a `cp` / `mv` / `mkdir -p` / `chmod` in stamping or promotion exits non-zero with a permission / `EPERM` signature under a restricted-filesystem sandbox.

The diagnostic names three things (a fourth for shell writes):

1. **The exact path** the write was attempting — the literal file (e.g. `.claude/skills/langchain-context/references/streaming.md`), never a glob or a generality.
2. **The exact remedy** — either add a scoped `sandbox.filesystem.allowWrite` entry *for that path* to the user's settings, or remove the `deny` rule that covers it. Scoped to the path, not the whole tree.
3. **The exact retry** — the engine workflow to re-invoke once the grant is widened, chosen by which surface failed: `/skill-engine:apply <name>`, `/skill-engine:engine-bootstrap`, or `/skill-engine:discover` / `/skill-engine:refresh`.
4. **(Shell writes only)** the literal failed command — the exact `cp` / `mv` / `mkdir -p` / `chmod` line — so the user can confirm the path and rerun it manually after widening the grant.

A tool-call-write diagnostic looks like this (the agent fills in the real path and the surface-appropriate retry command):

```
✗ Blocked writing .claude/skills/langchain-context/references/streaming.md

  The write was refused before it reached disk — a permission `deny` on
  .claude/**, or an OS-level sandbox restriction. This is your environment's
  guard, not an engine error.

  A permissions `allow` (including Edit(.claude/skills/**)) cannot lift either
  one: a `deny` always wins over an `allow`, and the sandbox sits below the
  permission layer entirely. To unblock this one path, do ONE of:

    • add a scoped sandbox.filesystem.allowWrite entry for the path, e.g.
        "sandbox": { "filesystem": { "allowWrite":
          [".claude/skills/langchain-context/references/streaming.md"] } }
    • or remove the `deny` rule covering .claude/** from your settings.

  Then re-run:  /skill-engine:apply langchain
```

A shell-write diagnostic adds the literal command that failed, e.g. `cp ... .claude/skills/langchain-context/verify.sh`, immediately under the path line, so the user can rerun it by hand once the grant is widened.

<!-- doctrine:sandbox-prose-exempt:start -->
**Why the grant alone cannot fix this — the two layers are independent.** Claude Code's permission rules (`allow` / `ask` / `deny`) and the OS-level sandbox are separate gates. A permission `allow` never overrides a user-level `deny` — deny-first wins across every settings scope — and it never overrides a sandbox restriction, which is applied to the Bash process below the permission layer entirely. Widening one gate says nothing about the other. The remedy is therefore always to *narrow* the block: a scoped `sandbox.filesystem.allowWrite` entry for the failing path, or removal of the specific `deny`. The remedy is **never** to disable the sandbox, to turn off the sandbox, or to run the engine without the sandbox. The engine will not ask a user to lower a machine-wide defense in order to write one file; the correct fix is always the narrow grant for the path that was blocked.
<!-- doctrine:sandbox-prose-exempt:end -->

### Forward note: Node.js hook portability

The constraint stack for this engine is bash + markdown + JSON only — no Node.js, no third-party deps. A future engine plugin (a forthcoming surface this guide does not yet describe in detail) may relax that for hook scripts specifically, since hooks run inside the Claude Code process and can portably invoke `node` on every Tier 1 platform. That's a deliberate later question; in the v1 contract documented here the engine stays bash-pure.

## Hooks

Claude Code supports event-driven hooks (`SessionStart`, `PreToolUse`, `PostToolUse`, `PreCompact`, etc.) that execute scripts at well-defined points in the agent lifecycle. The engine's hook policy is deliberately minimal:

**The scaffolder ships zero hooks.** When a user runs the bootstrap workflow to create a new contextualizer, the result is a navigator skill plus references plus the research agent template. There's no engine state to hydrate, no per-session context to inject — the navigator skill loads itself when invoked. Adding hooks here would be paperwork without payoff.

**A future engine plugin will ship exactly one inline `SessionStart` hook.** When the engine ships as a Claude Code plugin in a later release, the plugin will need to hydrate engine state (the catalog of tracked sources, the per-source SHA cache) at session start. That hook will be **inline** — defined directly in `settings.json` rather than as a separate script — because [Issue #18610](https://github.com/anthropics/claude-code/issues/18610) reports script-based hooks are broken on native Windows. Inline hooks work on every platform tier; script hooks don't. One inline hook, no shell scripts, no portability worry.

**The non-choices.** A few hooks that look attractive at first glance are deliberately *not* used:

- **`PreCompact`** — skipped because engine state is already file-based (`research/.research-state.json`, the per-source SHA cache, the catalog) per [06-release-doctrine.md](06-release-doctrine.md). The compaction event has nothing to add.
- **`PostToolUse` for `verify.sh`** — skipped because `verify.sh` is a release-doctrine ritual, not a per-tool-call latency drag. It runs once at human-review time, not on every tool invocation.

**Hooks-vs-permissions interaction.** When the engine plugin's `SessionStart` hook hydrates state from outside the project root (typically `${CLAUDE_PLUGIN_DATA}/state/current.json`), your `.claude/settings.json` will need to grant `Read(${CLAUDE_PLUGIN_DATA}/**)` so the hook can read it. That's a permission scoped beyond project root, and it's intentional — engine state belongs to the plugin, not the project.

## What this chapter does NOT cover

Be honest about the boundaries:
* **Specific package manager patterns (npm, pip, Homebrew tap, etc.).** The CLI here is plain bash. If you'd rather ship via npm or a Homebrew tap, the install logic is the same, only the distribution wrapper changes.
* **Code-signing the Desktop zip.** Out of scope. If your organization requires signed artifacts, layer that on top.
* **Telemetry.** Out of scope. The CLI in the source project is fully offline; if you want install telemetry, that's a separate decision with its own privacy considerations.

[Next: 05-invariants.md - Tests-as-spec: byte-equality, catalog bijection, version consistency, frontmatter discipline](05-invariants.md)