# Security Policy

Thank you for taking the time to help keep `skill-engine` and its users safe.

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

`skill-engine` is pre-1.0. Only the latest `0.1.x` release receives security fixes. When `1.0` ships, this table will expand to cover the most recent minor line.

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

- The `skill-engine` plugin code under `plugin/skill-engine/` (skills, templates, scripts).
- The reference engine doctrine in `docs/` insofar as it instructs users to take an action that has a security consequence (e.g. a command that would exfiltrate secrets if followed literally).
- The verify-script and pre-push hook in `templates/`.

## Out of scope

- Vulnerabilities in a *consumer's* contextualizer plugin built using this engine. Those belong to the consumer's project.
- Vulnerabilities in Claude Code itself, the Anthropic API, or other Anthropic products — please report those through [Anthropic's responsible disclosure channel](https://www.anthropic.com/security).
- Static analysis findings on bash scripts: this codebase is reviewed against `shellcheck` when applicable; CodeQL does not analyze bash and is intentionally not enabled (see Task 12 / Section 10 of the repo-setup runbook).
- Social-engineering, physical security, or DoS against GitHub's infrastructure.
- Findings that require the user to clone-and-execute code from an untrusted fork without review.

## Safe harbor

Good-faith research on `skill-engine` conducted within the bounds of this policy is welcomed. The maintainer will not pursue legal action against researchers who follow the reporting process above and avoid privacy violations, data destruction, or service degradation while investigating.
