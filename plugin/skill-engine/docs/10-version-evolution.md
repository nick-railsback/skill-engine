# 10-Version Evolution

**Question locked:** How do we handle version evolution when scaffolder v0.1 and engine v0.1 ship together, and users upgrade?

This chapter maps the versioning strategy for the skill-engine ecosystem where the scaffolder is shipped inside the engine plugin as a built-in workflow (locked 2026-05-07). It covers version numbering, template compatibility, state schema evolution, and backward-compatibility windows.

**Short answer:** Single unified version across the ecosystem. The engine plugin version = scaffolder version = templates version. Contextualizers are resilient to forward-compatible template changes; breaking template changes trigger a MAJOR version bump with explicit migration paths in the CLI.

## One ecosystem, one version

The engine plugin (`skill-engine` or `agent-skill-engine`), the scaffolder (inside it), and the templates (shipped with the scaffolder) share a **single semantic version** number.

```
skill-engine v0.2.0
  ├─ scaffolder v0.2.0
  ├─ engine-bootstrap-templates/ (all templates at v0.2.0)
  └─ engine workflows (REFRESH, SKILL, NEW, DISCOVER) at v0.2.0
```

**Why one version, not three:**
- Users see one artifact when they install: `skill-engine v0.2.0`.
- A breaking change in templates affects scaffolder scaffolding AND existing contextualizers; splitting versions masks that coupling.
- The three layers are load-bearing together: you cannot claim "scaffolder is v0.2, but templates are v0.1" because those templates were scaffolded by v0.1's scaffolder and may not work with v0.2's engine.
- One version number is simpler to reason about and test.

## Version numbering (MAJOR.MINOR.PATCH)

Applied to the engine plugin as a whole:

| Version bump | When | Example |
|---|---|---|
| **MAJOR** (e.g., 0.1.0 → 1.0.0) | Breaking change to: the template schema (discover-config, source-paths), the CLI scaffolding interface, or the engine's workflows (REFRESH, SKILL, NEW, DISCOVER). Any change that requires user action (migration, re-scaffolding) to stay compatible. | Changing the shape of `research/source-paths.json` in a non-additive way |
| **MINOR** (e.g., 0.1.0 → 0.2.0) | New scaffolder features (new template type, new CLI flag), new engine workflows, new optional fields in schema (forward-compatible), performance improvements, bug fixes. No action required from existing users. | Adding an optional `"cadence.LAZY_REFRESH"` field to research-state; adding a `--preserve-existing-references` flag to scaffolder |
| **PATCH** (e.g., 0.1.0 → 0.1.1) | Bug fixes in engine logic, doc improvements, performance tweaks that don't change the schema or CLI contract. | Fixing a clone-step race condition, improving SHA-comparison speed in REFRESH |

**Why this works:** A user scaffolding with v0.1 gets templates with v0.1's shape. Those templates work with v0.1's engine workflows. When they upgrade to v0.2, the scaffolder can optionally regenerate new templates (opting in to new features) or leave existing templates alone (v0.1 templates work with v0.2's engine because we only add forward-compatible fields, never remove or change existing ones).

## Template compatibility: forward vs. breaking changes

### The contract: forward compatibility by default

**Every template and schema evolves via addition, not deletion or structural change.**

When you want to add a new field to `discover-config.json`:

**v0.1 template:**
```json
{
  "version": "1.0",
  "hubs": [ ... ],
  "consumer_probes": [ ... ],
  "excluded_patterns": [ ... ]
}
```

**v0.2 template (forward-compatible change):**
```json
{
  "version": "1.0",
  "hubs": [ ... ],
  "consumer_probes": [ ... ],
  "excluded_patterns": [ ... ],
  "lifecycle_history": []
}
```

The v0.2 engine reads both:
- A v0.1 contextualizer's `discover-config.json` without the `lifecycle_history` field? The engine applies a safe default (`lifecycle_history = []`) when reading.
- A v0.2 contextualizer's config with `lifecycle_history`? The engine uses it.

**Result:** A v0.1 contextualizer works unchanged with the v0.2 engine. No migration required.

### When breaking changes happen: MAJOR version

If you need to change the structure of `research/.research-state.json` in a way existing state files don't understand:

**Old schema (v0.1):**
```json
{
  "skills": {
    "<area-domain>-sso": {
      "resources": [ { "last_commit_sha": "abc123", ... } ]
    }
  }
}
```

**New schema (v1.0, breaking):**
```json
{
  "schema_version": "2",
  "skills": {
    "<area-domain>-sso": {
      "resources": [ { "sha": "abc123", "metadata": { ... } } ]
    }
  }
}
```

This is a MAJOR bump (0.x → 1.0). The CLI's `detect_legacy_installation()` and `clean_legacy_artifacts()` flow from [04-delivery.md](04-delivery.md) applies here too:

1. **Detect:** On upgrade, the CLI reads the metadata file and sees `"version": "0.1.0"`.
2. **Signal:** Inform the user: "Found v0.1 contextualizer. Running migration to v1.0 schema."
3. **Migrate:** Rewrite `research-state.json` from old schema to new. Preserve all information (last_commit_sha → sha, etc.). If migration is not lossy, do it automatically. If lossy, pause and ask.
4. **Validate:** Run the engine's validation checks on the migrated state before proceeding.
5. **Record:** Update the metadata file to `"version": "1.0.0"`.

## State schema evolution

The `research/.research-state.json` is the ground truth for freshness, resource tracking, and session history. It evolves carefully.

### v0.1 schema (locked with engine v0.1)

```json
{
  "version": "1.0",
  "last_updated": "2026-04-20T14:23:11Z",
  "cadence": {
    "REFRESH": { "fresh_days": 7, "stale_days": 14 },
    "SKILL": { "fresh_days": 14, "stale_days": 30 },
    "DISCOVER": { "fresh_days": 14, "stale_days": 30 }
  },
  "skills": {
    "<area-domain>-sso": {
      "last_updated": "2026-04-20T09:11:07Z",
      "resources": [
        {
          "url": "https://...",
          "type": "internal-repo",
          "last_crawled": "2026-04-20T09:08:17Z",
          "last_commit_sha": "0123456a",
          "files_of_interest": ["src/auth/**", "docs/sso.md"]
        }
      ]
    }
  },
  "sessions": {
    "2026-04-20-refresh-abc": {
      "type": "REFRESH",
      "started_at": "2026-04-20T14:01:00Z",
      "skills_affected": ["<area-domain>-sso"]
    }
  }
}
```

**Key:** `"version": "1.0"` is the **schema version**, not the engine version. It tracks the structure of the JSON itself.

### Forward-compatible changes (MINOR bumps)

**v0.2 adds optional freshness tracking per workflow:**

```json
{
  "version": "1.0",
  "last_updated": "2026-04-20T14:23:11Z",
  "cadence": { ... },
  "skills": {
    "<area-domain>-sso": {
      "last_updated": "2026-04-20T09:11:07Z",
      "workflow_last_ran": {
        "REFRESH": "2026-04-20T14:01:00Z",
        "SKILL": "2026-04-19T10:30:00Z"
      },
      "resources": [ ... ]
    }
  },
  "sessions": { ... }
}
```

The engine v0.2 reads v0.1 state files (missing `workflow_last_ran`? Initialize to null). v0.1 engine reads v0.2 state files (ignores the new field). **No migration needed.**

### Breaking changes (MAJOR bumps)

If the schema redesign is substantial - e.g., moving from per-skill tracking to per-reference tracking - that's a new `schema_version`:

```json
{
  "version": "2.0",
  "last_updated": "2026-04-20T14:23:11Z",
  "references": {
    "<area-domain>-sso": { ... },
    "<area-domain>-mfa": { ... }
  },
  "sessions": { ... }
}
```

On upgrade from engine v0.x to v1.0:
1. Detect old `research-state.json` with `"version": "1.0"`.
2. The engine's migration routine transforms per-skill tracking → per-reference tracking.
3. Write the new `"version": "2.0"` schema.
4. Update the CLI metadata: `"engine_version": "1.0.0"` (separate from schema version).

**The metadata file now has two version fields:**

```json
{
  "tool": "claude",
  "engine_version": "1.0.0",
  "research_schema_version": "2.0",
  "installed_at": "2026-04-20T14:23:11Z",
  "skills": ["<area-domain>-context"]
}
```

This lets future installers know: "engine v1.0, but state schema is at v2.0, which means this contextualizer has already been migrated."

## Backward-compatibility window

**Policy:** The engine plugin supports reading contextualizers scaffolded by the **current and immediately previous MAJOR version**.

| Current engine | Reads v0.x contextualizers? | Reads v1.x contextualizers? | Notes |
|---|---|---|---|
| v0.1 | Yes (self) | n/a | First release; no prior version to read |
| v0.2 | Yes (v0.1 templates work) | n/a | MINOR bump; forward-compatible |
| v1.0 | Yes (v0.x contextualizers migrate) | Yes (self) | MAJOR bump; v0.x contextualizers require one-time migration |
| v2.0 | No (drop v0.x support) | Yes (v1.x templates work, new features optional) | MAJOR bump; v0.x contextualizers must upgrade via v1.0 first or re-scaffold |

**Why this window?** 
- Supporting two versions back (v2.0 supporting v0.x) doubles migration complexity with diminishing returns.
- The "upgrade via intermediate version" path exists: a user on v0.1 can upgrade to v1.0 (which fully supports v0.1), then v2.0 (which fully supports v1.0).
- The engine is not a database with years of versioned state. Contextualizers are user-managed code; upgrading is a deliberate action, not a surprise system update.

## Scaffolded contextualizers and upgrades

A user scaffolds a new contextualizer with engine v0.2:

```bash
skill-engine scaffold --name identity-context --domain identity
# produces:
# - skills/identity-context/
# - research/.research-state.json (schema v1.0)
# - discover-config.json (v0.2 shape)
# - All templates at v0.2
```

When engine v1.0 ships with new capabilities:

**Option A: Do nothing.** The contextualizer keeps working. The engine v1.0 understands v0.2 templates. Future `DISCOVER` improvements benefit them automatically if they upgrade the engine.

**Option B: Opt into new templates.** Run the scaffolder again with `--preserve-existing-references`:

```bash
skill-engine scaffold --name identity-context --preserve-existing-references
# Updates discover-config.json and templates to v1.0 shape
# Preserves existing references/ and research-state.json
```

**Option C: Start fresh.** Clean install of v1.0 engine with fresh scaffolding. Migrate old references manually (copy their content, run a targeted SKILL workflow to update the resource tracking).

## The tight integration: scaffolder and engine as one plugin

Because the scaffolder is shipped inside the engine plugin (as locked), version changes are atomic:

- Users install `skill-engine v0.2`: they get scaffolder v0.2 and all templates at v0.2.
- Users upgrade `skill-engine v0.2 → v1.0`: if they re-run `scaffold`, they get scaffolder v1.0 and templates v1.0. If they don't re-run `scaffold`, old contextualizers still work.
- There is no scenario where "scaffolder is v0.2 but engine is v1.0" because they ship as one plugin.

There is no separate doctrine repo and no separate scaffolder repo. The unified `skill-engine` plugin IS the public artifact, carrying its own canonical chapters as `docs/` and its own scaffolder as workflow #7. One version, one release cadence, one public surface.

## Version consistency and testing

The plugin states its version in several places; they must not drift. The
release-bearing surfaces are **mechanically gated** by the version-parity check
in [`tests/doctrine.sh`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/tests/doctrine.sh)
(run on every PR by the Security/lint workflows); the remaining surfaces are
manual review at bump time.

| Surface | Version location | Checked by |
|---|---|---|
| 1. Plugin manifest | `.claude-plugin/plugin.json` `"version"` | `doctrine.sh` version-parity check |
| 2. Marketplace entry | `.claude-plugin/marketplace.json` `plugins[0].version` | `doctrine.sh` version-parity check |
| 3. README version badge | `README.md` `badge/version-vX.Y.Z` | `doctrine.sh` version-parity check |
| 4. README prose | `README.md` "This is vX.Y.Z" | `doctrine.sh` version-parity check |
| 5. Doc example blocks | In this file (10-version-evolution.md) and chapter examples | manual review per CHANGELOG |

The `doctrine.sh` check fails CI when surfaces 1–4 disagree, so a missed bump on
any of them is caught before merge. (There is no `test_*`-named unit test for
this — the gate is the `doctrine.sh` grep/jq check, not a pytest function.)

When you bump the version:
- Update `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and both
  README spots (badge + "This is vX.Y.Z") to the same `X.Y.Z`.
- Update example version blocks in this doc to show the new shape.
- Regenerate any CHANGELOG-referenced example output.
- Run `bash plugin/skill-engine/tests/doctrine.sh` to confirm parity (`Failed: 0`).

## Migration by version pair

### v0.1 → v0.2 (MINOR: forward-compatible)

**What changes:** Optional fields added to templates and state schema.

**User action required:** None. Run `skill-engine update` to upgrade the engine; existing contextualizers work unchanged.

**CLI behavior:**
```bash
detect_legacy_installation()
# Returns: "none" (v0.1 contextualizers are compatible with v0.2 engine)

install_skills()
# Re-installs updated engine; contextualizer's research-state.json left as-is
```

### v0.x → v1.0 (MAJOR: breaking schema change)

**What changes:** `research-state.json` schema redesigned; template structure evolved.

**User action required:** One-time migration via CLI or manual re-scaffolding.

**CLI behavior:**
```bash
detect_legacy_installation()
# Returns: "0.1" (version from metadata file; schema is incompatible)

clean_legacy_artifacts()
# Does NOT remove research-state.json
# Backs it up to research/.research-state.v0.1.json

install_skills()
# Installs engine v1.0

migrate_state_schema()
# Reads research-state.v0.1.json
# Applies transformation rules: per-skill → per-reference, etc.
# Writes research-state.json (v1.0 schema)
# Validates the migrated state
# Prints: "Migrated research state from v0.1 to v1.0. Backup saved to research-state.v0.1.json"
```

If migration is lossy (information cannot be preserved), the CLI pauses:
```
The v0.1 schema stored [X] field, which does not map cleanly to v1.0.
Please review the backup and confirm the migration:
[show diff]
Continue? (yes/no)
```

## Contextualizer portability across upgrades

A contextualizer built with engine v0.1:

```
identity-context/
├── .claude-plugin/
│   └── plugin.json
├── skills/identity-context/
│   ├── navigator.md
│   └── references/
│       ├── identity-sso.md
│       ├── identity-mfa.md
│       └── identity-provisioning.md
├── research/
│   ├── .research-state.json (v0.1 schema)
│   └── sessions/
├── discover-config.json (v0.1 shape)
└── verify.sh
```

When engine v1.0 ships, this contextualizer:
- **Can be used without changes** if the user doesn't need new v1.0 features.
- **Can be opted into new templates** via `--preserve-existing-references` to take advantage of new engine capabilities.
- **Can be re-scaffolded entirely** if the user wants to start fresh (new references, new DISCOVER hubs).

## Discovery and DISCOVER schema evolution

The `discover-config.json` schema is part of the overall engine version, but DISCOVER itself is a mature feature (Phase 2 adoption, not Phase 0). It gets its own versioning:

```json
{
  "_comment": "DISCOVER configuration for the <area-domain>-context contextualizer. Schema: v1.0",
  "version": "1.0",
  "hubs": [ ... ],
  "consumer_probes": [ ... ],
  "excluded_patterns": [ ... ],
  "lifecycle_history": []
}
```

When DISCOVER schema evolves from v1.0 → v2.0 (part of engine v1.0):
- New contextualizers scaffolded with engine v1.0 get `discover-config.json` v2.0.
- Existing contextualizers with v1.0 config work with engine v1.0's DISCOVER workflows (forward-compatible: new optional fields ignored by old readers, old fields preserved by new readers).

If v2.0 DISCOVER schema is breaking, it's a MAJOR engine version bump with migration path in the CLI.

## Summary: version evolution principles

1. **One version number per release:** `skill-engine vX.Y.Z` = scaffolder vX.Y.Z = all templates at vX.Y.Z.
2. **Forward compatibility by default:** MINOR bumps add optional fields, never remove or restructure.
3. **Breaking changes trigger MAJOR bumps:** With explicit one-time migration paths in the CLI.
4. **Backward-compatibility window:** Current and previous MAJOR version only. Upgrade via intermediate versions if needed.
5. **Schema version tracking:** `research-state.json` embeds a schema-version field; metadata tracks both engine and schema versions.
6. **Test-enforced consistency:** Version assertions across five surfaces; test suite validates consistency per [05-invariants.md](05-invariants.md).
7. **User control over upgrades:** Contextualizers can stay on older templates or opt into new ones; no forced breakage.

[Next: (Reserved for future chapters on DISCOVER maturity, npm surface, or marketplace best practices)](README.md)
