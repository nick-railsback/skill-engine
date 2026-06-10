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

After the install completes, the plugin's twelve skills are loaded — they
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

The `discover` skill reads your source, then **stages** a proposal — the
curated navigator plus reference files — at a sibling
`<slug>-context.proposed/` directory. Nothing lands in the live
contextualizer yet; promotion is a separate, explicit step.

## 4.5 Review and promote

Reviewer-in-the-loop is the contract, so the staged proposal waits for
your sign-off:

```
/skill-engine:review <slug>
```

The first pass prints the proposal manifest, a diff command, and the
path to `REVIEW.md`; fill its Step 1 predictions and re-run the command
to generate the disagreement set. When you have signed off in Step 3,
promote the proposal:

```
/skill-engine:apply <slug>
```

(or `/skill-engine:discard <slug>` to drop it without promoting). Only
`apply` writes to the live contextualizer.

## 5. Keep it taught

When the upstream shifts, run `refresh`. The engine re-derives sources whose
content-hash changed and stages updated references the same way — through a
proposal that waits for `review` and `apply`. A refresh invoked while an
earlier proposal is still staged halts until you apply or discard it.

Run `status` any time to see what is on disk. Run `clean-cache` when you want
to free the local clone cache (dry-run is the default; type `yes` to delete).

That's the loop: discover once, refresh on change, review-and-apply every
proposal.
See [the doctrine](./doctrine.md) for the load-bearing decisions behind
these workflows.
