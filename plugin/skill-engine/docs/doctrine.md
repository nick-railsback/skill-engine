# Doctrine

This is a short log of the load-bearing decisions behind skill-engine — the
calls made when the path forked, and what a maintainer five years from now
would want to know about why the project landed where it did.

It's not exhaustive. It covers the decisions where the alternative was
tempting enough that someone three years from now might be tempted to undo
them, and where the reasons are worth writing down so the answer isn't
"nobody remembers."

The engine's chapters describe what the engine *does*. This document
describes what was *deliberately not built*.

## One plugin, not two

The alternative considered was shipping a separate scaffolder as its own
plugin, so the once-used setup workflow wouldn't sit in `~/.claude/plugins/`
forever. The call came down to plugin discovery: two plugins is two pieces
of context the user keeps, and the second one is a permanent reminder of a
workflow they ran once. The decision was one plugin — every workflow under
one name, smart entry-point routing on first run, no eviction problem.

A related call inside the same surface: the cache lifecycle moves through
four named stages — seed (the plugin asks before cloning anything),
garbage-collect on refresh, a read-only status surface, and an opt-in
`clean-cache` command that dry-runs by default and needs a literal `yes`
to delete. Small stages, in sequence, none of them automation the user
didn't ask for.

## Goal-given discovery

Discovery — the workflow that reads your codebase and writes the curated
index — originally followed a prescribed multi-stage worker pipeline. The
engine told the model how to identify important files, how to filter
commodity content, how to find related references, and which template to
use at each stage. It worked, but every stage carried scaffolding the
engine had to maintain, and the prescriptions got harder to keep coherent
each time the underlying model improved.

The pipeline was retired. The discovery workflow now hands the model a
task — *discover the essence of this codebase; write reference files for
the parts that matter; satisfy these four output invariants* — and lets
it execute in whatever shape it decides. The engine validates the output,
not the path. As models get more capable, the path forward was to get
out of the way, not to add more instrumentation.

## Thin sources, file-level citations

Each source in a contextualizer is identified by its content-hash — when
the source changes, the hash changes, the engine knows to re-derive. With
that primitive in place there was a tempting next step: carry *chunk-level*
granularity in the persisted state, so citations could resolve to a
specific slice inside a long document, refresh could re-process only
changed slices, and sources could be ranked by chunk-level relevance.

That layer didn't ship. Citations resolve by file path and content-hash;
that's enough. The chunks layer would have multiplied the persisted-state
schema, added a tier of bookkeeping the engine has to maintain, and solved
a problem the engine doesn't have. Most contextualizers in the wild are
tens of sources, not thousands; cold-cache refresh runs in seconds and
costs cents. The layer can be added later if a real refresh-cost problem
shows up. None has surfaced yet.

## Examples are validation, not packs

Most projects ship their trial work as polished examples — a "here's the
engine working on this real codebase" reference pack. The decision here
was not to. The reason is what trial work is *for*: a trial teaches the
project something the project couldn't have learned by thinking. Once the
lesson lands, the trial has served. Polishing it for public consumption
is a different job — case-study writing — that requires re-doing the work
to a higher standard than a trial deserves.

What lives under `examples/` is one worked example built from the start
as a worked example: opinionated about what it's teaching, scoped to make
the teaching land. If the engine works on your codebase the way it works
there, you've adopted the right tool. If the engine fights you in ways
the example didn't predict, that's a real signal — file an issue.
