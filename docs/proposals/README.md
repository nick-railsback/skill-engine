# Proposals

Design ideas for skill-engine that have not shipped. Each entry is a feature
direction the project is thinking about out loud — the problem it would solve,
the shape it might take, and what is still unresolved — written down before any
code exists so the reasoning is on the record when the work (or the decision not
to do the work) eventually happens.

This is deliberately separate from the engine's chapters under
[`plugin/skill-engine/docs/`](../../plugin/skill-engine/docs/), which describe
what the engine *does* today, and from
[`doctrine.md`](../../plugin/skill-engine/docs/doctrine.md), which records what
was deliberately *not* built. A proposal is the third thing: what *could* be
built, and is being weighed.

## The contract this directory keeps

- **Status is stated, at the top, honestly.** Every entry leads with a status
  line. "Proposed" means exactly that — no part of it ships. Where a proposal
  builds on behavior the engine already has, the prose says which paragraphs
  describe today and which describe the proposal. A reader must never have to
  guess whether a sentence is a feature or a wish.

- **Grounded in the engine as it actually is.** A proposal cites the real files,
  invariants, and pipeline stages it would touch or change. It is an
  engineering argument, not a vision statement.

- **Open questions are listed, not hidden.** The unresolved parts are the most
  useful part of a proposal. Each entry ends with what it does not yet know.

- **A proposal graduates or it doesn't.** When an idea ships, its behavior moves
  into the engine chapters and the load-bearing call moves into `doctrine.md`;
  the proposal is deleted, because the canon now documents the real thing. When
  an idea is rejected, it either leaves a one-line entry in `doctrine.md` (if the
  *not*-building was itself a load-bearing call) or is simply removed. Stale
  proposals are a maintenance tax this directory does not pay.
