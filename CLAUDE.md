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

**Green here is not green in CI.** `ci-local` covers `lint.yml` and
`hooks-audit.yml` in full. `security.yml` is a third workflow, and three of its
gates run nowhere locally: `bandit --severity-level high`, `semgrep --severity
ERROR`, and gitleaks. They stay out on purpose — semgrep resolves `p/ci` and
`p/secrets` from the registry, so folding them in would cost `ci-local` the
no-network property that makes it cheap enough to run on every change. That
residual is to be absorbed, not forgotten: when a change touches Python under
`plugin/skill-engine/tests/`, run the two gates by hand before proposing the
commit.

    bandit -r plugin/skill-engine/tests --severity-level high -q
    semgrep scan --config p/ci --config p/secrets \
      --config .semgrep/skill-content.yml --severity ERROR --error

## Versions

Six version surfaces across five files move together, and `/release` is what
moves them. Never bump one by hand: `doctrine.sh`'s version-parity check fails
the build when they disagree, which is the point.

## Git

Nothing is committed, pushed, tagged, or released on the maintainer's behalf —
prepare the change, then surface the commands for them to run. `git commit`,
`git push`, `git tag` and `gh release create` are all ask-gated in
`.claude/settings.json`, so the rule has mechanical backing; keep the two in
step if either changes. `git add` is not ask-gated — staging isn't
publishing, and re-confirming it on every save was pure friction.
