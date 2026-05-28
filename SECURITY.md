# Security Policy

Thank you for taking the time to help keep `skill-engine` and its users safe.

## Safety model

This plugin narrows the blast radius of accidental destructive commands the assistant might propose. It does not protect against: malicious dependencies, compromised LLM outputs that paraphrase around the permission rules, or you approving a dangerous command when distracted. It is a seatbelt, not a vault.

The bundled `.claude/settings.json` is where that seatbelt is buckled: an `ask` list gates the common mutating git verbs, recursive removes (`rm -rf`, `rm -r`), and writes into your installed-skills tree behind a prompt; the `deny` list is deliberately empty, because a bundled repo-level settings file that hard-refused `git commit`/`git push` would also block your own Claude-driven work in this repo, not just the engine; and a near-empty `allow` list grants only read access plus four read-only git verbs. These are user-overridable, merge-based Claude Code permissions — they express intent legibly, not enforcement. Anyone can read the file and see exactly what trust the engine asks for.

### What we check / what we don't

The repository's automated checks look for a narrow, well-defined set of problems:

- **shellcheck** flags common shell mistakes — unquoted expansions, unset variables, fragile constructs — across every script. (This one runs today, in the lint workflow.)
- **gitleaks** greps the diff for things that look like committed API keys, tokens, or other secrets.
- **semgrep** matches code against rules for known-risky patterns across languages.
- **bandit** scans Python for common security anti-patterns, should any Python land in the tree.

The broader scanning suite (`gitleaks`, `semgrep`, `bandit`) is wired through the CI security workflow (`.github/workflows/security.yml`), which runs on every pull request, on pushes to `main`, and on a weekly schedule. bandit and semgrep findings surface in the repository's Security tab.

What these checks do *not* do, and are not meant to:

- **No validation of skill behavior at activation time.** A skill that parses cleanly and passes every linter can still give Claude bad guidance. The reviewer-in-the-loop model — every upstream change enters as a proposal, never an auto-merge — is what catches that, not a scanner.
- **No prompt-injection detection.** Nothing here inspects upstream content for instructions aimed at the assistant.
- **No SLSA provenance or SBOM.** See "What this policy does not promise" below.

### The one hook we ship, and why we ship no others

The plugin declares exactly one hook: a `SessionStart` bootstrap hook, declared inline in the plugin manifest's `hooks` key (`plugin/skill-engine/.claude-plugin/plugin.json`). It does one thing — hydrate the engine's own state. On a fresh session it creates `${CLAUDE_PLUGIN_DATA}/state/current.json` if it is absent, validates that it parses as JSON if it is present, and emits a one-line notice on stderr. It guards on `CLAUDE_PLUGIN_DATA` and `jq` being available, touches only the plugin's own data directory, and always exits 0, so it can never block a session. The inline-`hooks` form is idiomatic per the official plugin examples ([`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official)) and conforms to the current plugin-manifest schema.

The engine ships no other hooks, and it injects none into your `.claude/settings.json`. Hooks fire automatically on your events; an engine that quietly registered hooks in your settings would be acting without a prompt — exactly the trust this project refuses to ask for. That refusal rests on three layers:

- **Doctrine** — the project's standing rule that the engine adds no hooks to your settings and mutates no git state on your behalf.
- **The `make hooks-audit` target** — a check that fails if the plugin's declared hooks drift from the single one documented here. It runs locally in under five seconds (`make hooks-audit`) and in CI on every pull request, so drift surfaces as a failing check rather than something a reviewer has to remember to look for.
- **The empty `hooks` block** in the bundled `.claude/settings.json` — a committed, zero-hook settings file whose every future change shows up in `git diff`. This is the layer you can read right now.

### What this policy does not promise

This is a single-maintainer, pre-1.0 plugin. Several things a hardened supply chain would provide are deliberately out of scope, and naming them is more honest than implying they exist:

- **SLSA provenance** — releases carry no build-provenance attestation.
- **SBOM** — no software bill of materials is generated.
- **Reproducible builds** — there is no build step to reproduce; the plugin is shell and Markdown.
- **Container scanning** — the project ships no container image.
- **Signed releases** — release tags and artifacts are not cryptographically signed.

If your threat model requires any of these, this plugin does not meet it yet. Vendor it, fork it, or wait for a release that does.

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |

`skill-engine` is pre-1.0. Only the latest pre-1.0 minor line (currently `0.3.x`) receives security fixes; prior minor lines are end-of-life. When `1.0` ships, this table will expand to cover the most recent minor line plus a backport window.

## Reporting a vulnerability

**Please do not file security issues as public GitHub issues.** Instead, use GitHub's Private Vulnerability Reporting flow:

1. Navigate to the [Security tab](https://github.com/nick-railsback/skill-engine/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the form with as much detail as you can: affected version, reproduction steps, expected vs actual behavior, and any proof-of-concept or scope notes.

### What to expect

- **Acknowledgement**: within 7 days of submission.
- **Triage update**: within 14 days, including a severity assessment and an indication of whether the report is in scope.
- **Fix timeline**: depends on severity; critical issues are prioritized over feature work. You will be kept informed.
- **Credit**: with your permission, reporters are credited in the release notes or advisory that announces the fix.

If you do not receive an acknowledgement within 7 days, please open a *non-sensitive* public issue (e.g. "Awaiting response on a private security report submitted YYYY-MM-DD") so the maintainer is nudged — do **not** include the vulnerability details in that issue.

## Scope

In scope:

- The `skill-engine` plugin code under `plugin/skill-engine/` (skills, agents, bundled scripts, and bootstrap templates).
- The reference engine doctrine in `docs/` insofar as it instructs users to take an action that has a security consequence (e.g. a command that would exfiltrate secrets if followed literally).
- The `verify.sh` script and the `pre-commit.sh.template` hook under `plugin/skill-engine/engine-bootstrap-templates/`.

## Out of scope

- Vulnerabilities in a *consumer's* contextualizer plugin built using this engine. Those belong to the consumer's project.
- Vulnerabilities in Claude Code itself, the Anthropic API, or other Anthropic products — please report those through [Anthropic's responsible disclosure channel](https://www.anthropic.com/security).
- Static analysis findings on bash scripts: this codebase is reviewed against `shellcheck` when applicable; CodeQL does not analyze bash and is intentionally not enabled (see Task 12 / Section 10 of the repo-setup runbook).
- Social-engineering, physical security, or DoS against GitHub's infrastructure.
- Findings that require the user to clone-and-execute code from an untrusted fork without review.

## Safe harbor

Good-faith research on `skill-engine` conducted within the bounds of this policy is welcomed. The maintainer will not pursue legal action against researchers who follow the reporting process above and avoid privacy violations, data destruction, or service degradation while investigating.
