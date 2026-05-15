# skill-engine

**Teach Claude your codebase. Keep it taught.**

skill-engine is a Claude Code plugin that builds and maintains a
contextualizer — a curated index of one codebase that Claude reads before
it answers. The plugin bundles the maintenance, scaffolder, and
cache-hygiene workflows you'll use across a contextualizer's lifecycle.

## First run

After bootstrap, the engine inspects the new `source-paths.json` and may
ask whether to pre-clone referenced repos into the cache at
`~/.cache/skill-engine/`. The prompt defaults to **No** — the engine works
fine without the cache; pre-cloning is purely an optimization for `discover`
runs and amortizes across subsequent `refresh` cycles. You can say yes later
(you'll be re-offered when `discover` detects a cache miss for an in-scope
git-managed source), or never. The engine does not clone without your
explicit consent.

See the repo
[`README.md`](https://github.com/nick-railsback/skill-engine/blob/main/README.md)
for the audience map and a worked example, and
[`docs/doctrine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/doctrine.md)
for the load-bearing decisions behind the engine's shape.
