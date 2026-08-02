# Dogfood eval — first live run

**Date:** 2026-08-02 (started 09:02:08Z)
**Corpus:** `evals-train.json` (15 entries, 3 runs each = 45 `claude` CLI invocations)
**Errors:** 0 — every invocation returned a routing verdict, none failed at the CLI layer.

**Majority-vote pass rate:** 12/15 overall (80%) — 4/5 domain-expert, 4/5
domain-naive-technical, 4/5 non-technical.

**Flicker (disagreed across the 3 runs):** 2 entries.
- "Why can't I just add a little header block to the top of a reference
  file..." (→ artifact-contract) — fail, pass, fail (majority fail).
- "How would I know whether the answers I'm getting are actually backed by
  real source material..." (→ evaluation-and-audit) — pass, fail, pass
  (majority pass).

**Unanimous fails:** 2 entries, both routed at the `principles` reference —
"What's the design rationale for goal-given delegation over a fixed
pipeline..." and "Why doesn't the tool just go fetch and clone everything it
finds on its own...", each fail/fail/fail. Both were deliberately authored as
a near-duplicate pair against `discover-refresh`'s goal-given-posture and
consent-gate entries (same topic, different reference) specifically to probe
whether the navigator's routing can disambiguate general design-philosophy
framing from pipeline-specific mechanics — on this run it consistently could
not, routing both to a different reference than the one intended. This looks
like a real navigator-description gap worth a maintainer follow-up, not an
eval-authoring defect; results file: `results-20260802T090208Z-59838.json`.
