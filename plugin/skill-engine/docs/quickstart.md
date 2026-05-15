# Quickstart

This walks you from a fresh clone of skill-engine to a working contextualizer
for one codebase you maintain. Plan on twenty minutes.

## 1. Register the marketplace

In any Claude Code session:

```
/plugin marketplace add nick-railsback/skill-engine
```

This registers the repository as a plugin marketplace. The command should
report `Added marketplace: skill-engine-marketplace`.

## 2. Install the plugin

```
/plugin install skill-engine@skill-engine-marketplace
```

After the install completes, the plugin's eight skills are loaded — they
activate when Claude detects the matching intent in your session.

## 3. Bootstrap a contextualizer

Open a fresh directory for your contextualizer (one per codebase you
maintain):

```
mkdir ~/git/my-codebase-context
cd ~/git/my-codebase-context
```

In a Claude Code session opened in that directory, ask Claude to bootstrap:

> Bootstrap a contextualizer here for `<source-url-or-local-path>`.

The `engine-bootstrap` skill stamps the project layout, detects identity and
topology from the source you named, asks once whether to pre-clone referenced
repos into the local cache (default: no), and prints a three-line next-step
message naming `discover` as the workflow to run next.

## 4. Discover the corpus

In the same directory:

> Run discover.

The `discover` skill reads your source, writes the curated index, and
proposes reference files. Review the proposals before they land — the engine
pauses for your approval; reviewer-in-the-loop is the contract.

## 5. Keep it taught

When the upstream shifts, run `refresh`. The engine re-derives sources whose
content-hash changed and proposes updated references for review.

Run `status` any time to see what is on disk. Run `clean-cache` when you want
to free the local clone cache (dry-run is the default; type `yes` to delete).

That's the loop: discover once, refresh on change, review every proposal.
See [the doctrine](./doctrine.md) for the load-bearing decisions behind
these workflows.
