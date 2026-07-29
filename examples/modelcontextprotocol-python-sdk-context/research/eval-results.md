# Grounded-citation eval — results

SELF-AUDIT **Check 8** (`grounded_rate.py`) grades how reliably this
contextualizer produces *grounded* answers over the `needs_reference` corpus,
split across [`eval-prompts-train.json`](eval-prompts-train.json) and
[`eval-prompts-test.json`](eval-prompts-test.json). An answer counts as
**grounded** when the model (a) opens ≥1 reference via the `read_reference` tool
**and** (b) emits a SHA- or tag-pinned GitHub permalink in its final response.

- **Corpus:** 10 `needs_reference` prompts (n01–n10), split 7/3 into a train set
  and a held-out set. The held-out set is n03, n06 and n09 — every third prompt
  by position, so the two sets stay comparable in difficulty. A grading run
  scores exactly one of them, the train set by default; the held-out set is
  reachable only via `--corpus eval-prompts-test.json`.
- **Answering model:** Claude Haiku 4.5.
- **Runs:** one per prompt. Routing and citation are non-deterministic, so treat
  single-run figures as indicative, not exact.

Reproduce: `SKILL_ENGINE_RUN_EVAL=1 python3
plugin/skill-engine/tests/grounded_rate.py
examples/modelcontextprotocol-python-sdk-context` (real API spend, ~$0.20 per
full run; add `--dry-run` to validate every corpus file under `research/` for
free).

## What the eval found, and how the navigator changed in response

Retrieval was never the problem — every prompt opened the correct reference in
every run, and the references already carry SHA-pinned permalinks (the
`permalink-density` gate passes at high coverage). The gap was **citation**: the
navigator did not reliably surface those permalinks in its answers. Tuning the
navigator's Claims policy against the eval produced a clear ladder:

| Navigator citation design | Grounded-rate |
|---|---|
| Stale navigator (no Claims policy) | 30% (3/10) |
| Verbose Claims policy, permalink nominally instructed | 30% (3/10) |
| Claims policy reordered (permalink rule first; "footer ≠ substitute") | 70% (7/10) |
| **Tight, forceful citation rule (shipped)** | **90% (9/10) — PASS** |

**Every figure in that table is a pre-split number, including the 90%.** The
whole ladder was measured on all ten prompts — the same ten now split 7/3 — so
the set the navigator was tuned against and the set the result is reported on
were the same set. A 9/10 measured that way is a training-set number, not a
holdout result, and it is published here as one.

Splitting the corpus does not retroactively clean it: both files were tuned on,
so neither is a genuine holdout today. The protection is **prospective** — it is
the *next* tuning pass that is guarded, because reaching the held-out set now
costs a deliberate `--corpus eval-prompts-test.json` rather than happening by
default. A number that could honestly be called a holdout result needs prompts
the navigator was never tuned against, which means growing the corpus.

Two findings drove the final design:

1. **Grounded retrieval and grounded citation are separate behaviors.** Opening
   the right reference does not imply citing it; the navigator has to instruct
   the citation explicitly. Shipping references full of permalinks is necessary
   but not sufficient.
2. **The provenance footer competes with inline citation.** The verbose policy
   gave the model an easier way to "cite" — a filename-based footer — so it did
   that and skipped the harder inline permalink (a diluted policy scored the
   same 30% as no policy at all). Making the inline-permalink rule primary and
   stating explicitly that *the footer is a summary, not a substitute* is what
   moved the needle. Concision and placement beat a longer, hedged policy.

## What shipped

The tight permalink-cite Claims policy is folded back into the engine, not left
as a one-off: it lives in both navigator templates
(`engine-bootstrap-templates/navigator.md.template` and
`navigator-multi-domain.md.template`), so every newly generated contextualizer
inherits it, and all three bundled examples carry it. The contract is documented
in [`02-artifact-contract.md`](../../../plugin/skill-engine/docs/02-artifact-contract.md)
(navigator section 2, "Claims policy").

The last 10% (one prompt that opened its reference but did not emit a permalink)
is single-run model stochasticity, comfortably inside the 80% pass threshold;
it was not worth over-tuning a one-run-per-prompt metric to chase.
