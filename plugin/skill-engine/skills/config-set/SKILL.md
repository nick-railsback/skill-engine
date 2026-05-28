---
name: config-set
description: Set an engine-wide config value (currently the `review` diff tool).
---

# Config set

Persist an engine-wide configuration value. The single key the engine reads today is `diff.tool` — the command `/skill-engine:review` prints when surfacing how to inspect a proposed-vs-live diff. The default value is `git diff --no-index --color`; users with a preferred diff tool override it once and the choice persists across sessions.

## Argument shape

`/skill-engine:config-set <key> "<value>"`

Example invocations:

```
/skill-engine:config-set diff.tool "delta"
/skill-engine:config-set diff.tool "git diff --no-index --color"
/skill-engine:config-set diff.tool "code --diff"
```

The `<value>` is taken verbatim; quote it so shell-splitting does not eat embedded spaces. The engine does not validate that the configured command exists on the user's PATH — that is the user's responsibility. A misconfigured command surfaces as a runtime failure when `/skill-engine:review` prints it and the user runs it.

## Resolution of the config file

The config file lives at `$CLAUDE_PLUGIN_DATA/config.json`. This is the same plugin-data tree the existing `SessionStart` hook (declared in `plugin/skill-engine/.claude-plugin/plugin.json`) writes `state/current.json` to. The directory is created if absent.

When `$CLAUDE_PLUGIN_DATA` is unset, surface:

```
$CLAUDE_PLUGIN_DATA is unset. The engine's plugin-data tree is not reachable from this shell. Run the skill from a Claude Code session where the plugin is installed, or set $CLAUDE_PLUGIN_DATA to the engine's plugin-data directory.
```

Exit non-zero. Do not write a config file to a fallback location — the engine's other surfaces (the `SessionStart` hook, `/skill-engine:review`) all key off `$CLAUDE_PLUGIN_DATA`, and writing to a different path would create a config that the readers never find.

## The write

Read the existing `config.json` (or initialize an empty object if absent). Merge the new key/value into it, preserving any other keys present. Write back with `schema_version: 1` if not already set.

Example file shape after `/skill-engine:config-set diff.tool "delta"`:

```json
{
  "schema_version": 1,
  "diff.tool": "delta"
}
```

The flat key shape (`diff.tool` as one string, not nested) keeps the file shallow and matches the argument the user typed. Future keys (`diff.binary`, `cache.location`, etc.) follow the same shape.

## Exit message

```
Set diff.tool = "<value>" in $CLAUDE_PLUGIN_DATA/config.json.
```

## What this skill does NOT do

- It does not list current values. A separate `config-list` skill would be the symmetric surface; it is out of scope for the v0.3.0 review workflow.
- It does not unset values. Hand-edit `config.json` to remove a key, or set it back to the engine default.
- It does not validate the diff tool against the user's shell environment. The engine treats `<value>` as opaque.
- It does not gate keys against a schema. Any `<key>` accepted by the argument parser is written; readers (`/skill-engine:review`) read the keys they know and ignore the rest.
- It does not enforce read-only-ness on user-configured diff tools. The doctrine constraint "no engine git mutations" binds the engine, not user config (the `git.readonly` lint codifies engine-codebase read-only-ness).
