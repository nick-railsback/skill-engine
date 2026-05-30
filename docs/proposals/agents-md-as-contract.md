# AGENTS.md as contract

**Status: Proposed — not shipped.** This describes a feature direction. The
"What the engine already does" paragraph below is current behavior and is
labeled as such; everything under "The proposal" is not built.

## The idea

When a repository keeps an `AGENTS.md` (or `CLAUDE.md`, or `CONTRIBUTING.md`),
the discipline that makes it work is a one-way derivation: the human-readable
document is the source of truth, and the agent's behavior is *derived from* it.
A rule the agent follows that isn't written in the document is a private oral
tradition — invisible to the next human, invisible to the next AI assistant, and
the first thing to drift. The rule goes into the document first; the behavior
follows from the document, never the other way around.

That discipline is the same one skill-engine is built to keep. A generated
contextualizer is itself an `AGENTS.md`-class artifact: a human-readable
document that an agent reads to know a codebase's canon. So the contract idea
cuts two ways for this project — at the source the engine *reads*, and in the
contextualizer it *produces*.

## Why it fits — what the engine already does

The derive-from-the-document discipline already shows up in the engine, unnamed,
as three invariants:

- **Receipts.** The permalink lint requires ≥80% of load-bearing paragraphs to
  carry a permalink to upstream within five lines
  ([`13-coverage-testing.md`](../../plugin/skill-engine/docs/13-coverage-testing.md)).
  A claim in a reference must trace back to the source it was derived from. That
  is the derivation direction, enforced.
- **No drift.** `REFRESH` re-derives a reference when its source's content-hash
  changes ([`03-engine.md`](../../plugin/skill-engine/docs/03-engine.md)). The
  document is never allowed to quietly diverge from the canon it describes.
- **Legibility.** References are Markdown, not an opaque embedding — readable by
  the next human and the next agent, the same property that makes `AGENTS.md`
  worth keeping in the first place.

The engine, in other words, already operationalizes most of this contract. What
it does *not* yet do is treat a repository's own `AGENTS.md`-class files as
anything special, or close the loop back to them. That gap is the proposal.

## The proposal

### Part B — inherit the upstream's contract (read side)

**Today:** the engine has no special handling for a source's own `AGENTS.md`,
`CLAUDE.md`, or `CONTRIBUTING.md`. They are crawled as ordinary files, ranked by
the same relevance the model applies to everything else. (The monorepo adapter's
per-slice `CLAUDE.md` is a *different* mechanism — author-authored
context-shaping the engine doesn't read; Claude Code does. See
[`07-monorepo-adapter.md`](../../plugin/skill-engine/docs/07-monorepo-adapter.md)
§7.8.)

**Proposed:** when a registered source ships an `AGENTS.md`-class file, `DISCOVER`
treats it as a *privileged* source — the canon's own self-description of its
conventions — and prefers deriving convention-bearing references from it over
re-inferring conventions from raw code. This is the lesson the engine already
teaches elsewhere: when the rules are written down clearly, an explicit
checklist beats retrieval-and-reason on accuracy. A repository's `AGENTS.md` is
the single most convention-dense, most citable source of that truth, and the
engine currently leaves it on the floor with everything else.

Concretely, this is a discovery-time signal, not new engine machinery: a
discover-config hint that names these files, so the model weights them and the
resulting convention references cite them. It composes with the existing
pipeline rather than replacing any of it.

### Part A — the contextualizer is the contract (write side)

The sharper move is to recognize that the generated contextualizer *is* the
`AGENTS.md` the consuming agent reads — and to make the derivation invariant
explicit and bidirectional.

**A derivation invariant, named.** The permalink lint approximates "every rule
derives from a documented source" for load-bearing paragraphs generally. The
proposal is to name that as the contract it is and consider tightening it for
convention-class references specifically: a stated convention in a
contextualizer should be traceable to a place the upstream *documents* that
convention, not merely to a line of code that happens to embody it. A convention
without a documented home upstream is exactly the private oral tradition the
contract exists to prevent.

**Close the loop (the genuinely new capability).** When the engine derives a
convention that is *true of the code but written down nowhere* in the upstream's
own `AGENTS.md`, it should surface that as a proposed addition to the upstream
document — not silently encode it in the contextualizer. This mechanizes the
"the rule goes into `AGENTS.md` first" discipline: the contextualizer becomes a
feedback loop that keeps the human-readable contract current, instead of a
private index that slowly accumulates knowledge the humans' own document never
catches up to. The contextualizer stays a derivative of the contract; it never
quietly becomes a second, competing source of truth.

## What this is not

- **Not auto-writing to the upstream repo.** The closed loop *proposes* an
  `AGENTS.md` change for a human to accept. The engine never pushes to a source
  it reads.
- **Not a new source kind.** `AGENTS.md`-class files are read with the existing
  `git-managed` / `local-path` treatments; the proposal is a weighting and a
  feedback path, not a fifth kind.
- **Not the contextualizer becoming the canon.** If the contextualizer and the
  upstream `AGENTS.md` ever disagree, the upstream document wins, and the
  disagreement is a `REFRESH` signal — not license for the contextualizer to
  assert its own version.

## Open questions

- **Detection.** Is "named `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` at a
  source root" a good enough signal, or does privileging-by-filename invite
  gaming and false positives (a stale `CONTRIBUTING.md` that no longer reflects
  the code)? A privileged source that is itself drifted is worse than no signal.
- **The closed loop's surface.** Where does a proposed `AGENTS.md` addition go —
  a section in the `REFRESH` review output, a separate artifact, a comment? It
  must not become noise the maintainer learns to ignore.
- **Convention-traceability lint.** Can "this convention has a documented
  upstream home" be checked deterministically, the way permalink density is, or
  does it require a judgment call that doesn't belong in a lint gate?
- **Cost.** Does the read-side weighting earn its keep on sources that *don't*
  ship an `AGENTS.md`-class file, which is still the common case? If most
  registered sources have nothing to privilege, the feature is dead weight for
  them — and dead weight the engine carries is exactly what `doctrine.md` keeps
  warning against.
