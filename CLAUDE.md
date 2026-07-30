# skill-engine — standing rules

Domain knowledge is not here. It loads on demand from
`.claude/skills/skill-engine-context/` — the artifact contract, the reference
invariants, `verify.sh`'s checks, the workflows. Keep this file to rules that
apply on every turn; anything you'd have to look up belongs in that skill.

## Before proposing a commit

Run `make ci-local`. It is the complete local check — the same five suites
`.github/workflows/lint.yml` runs (shellcheck, json, doctrine, tests,
examples), with no network and no model calls. `make hooks-audit` is one of
those suites, not a substitute for the target.

## Versions

Six version surfaces across five files move together, and `/release` is what
moves them. Never bump one by hand: `doctrine.sh`'s version-parity check fails
the build when they disagree, which is the point.

## Git

Nothing is committed, pushed, tagged, or released on the maintainer's behalf —
prepare the change, then surface the commands for them to run. `git add`,
`git commit`, `git push`, `git tag` and `gh release create` are all ask-gated in
`.claude/settings.json`, so the rule has mechanical backing; keep the two in
step if either changes.
