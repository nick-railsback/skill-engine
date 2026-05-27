# Custom semgrep rules

This directory holds a small ruleset that the security workflow
(`.github/workflows/security.yml`) runs against the repository's markdown,
alongside the upstream `p/ci` and `p/secrets` registry packs.

The rules live in `skill-content.yml` and exist for one reason: **skill
markdown becomes agent context.** A dangerous command written in a reference
file or a skill instruction is not inert documentation — an agent reading it
may surface it to a user as a suggested command. These rules catch the
footguns most likely to be copied out of context, before they ship.

## How the rules work

Markdown is not a first-class semgrep language, so every rule runs in generic
mode and matches text with a regex:

- `languages: [generic]`
- `paths.include: ["*.md"]` — semgrep matches this glob against `.md` files at
  any depth, so it is equivalent to scoping the rules to `**/*.md`.
- `pattern-regex:` (or a `patterns:` block combining `pattern-regex` with
  `pattern-not-regex` to trim false positives).

Severity maps directly onto the workflow's gate:

| semgrep severity | workflow behaviour |
| ---------------- | ------------------ |
| `ERROR`          | fails the build    |
| `WARNING`        | surfaces in the Security tab, does not fail |
| `INFO`           | ignored            |

So `ERROR` is reserved for patterns that are dangerous with no legitimate
counterexample in this repository; softer patterns that show up in genuine
documentation are `WARNING`.

## The rules

- **`skill-content-curl-pipe-sh`** (`ERROR`) — a remote script piped straight
  into a shell (`curl ... | sh`, `wget ... | sh`). This runs unreviewed code;
  in agent context it can reach a user as a ready-to-run command. Download and
  review the script, or describe the steps instead. (Generic mode is
  line-oriented, so a backslash-continued pipe split across lines is not
  caught — keep the pattern on one line if you want it flagged.)

- **`skill-content-disable-sandbox-or-broad-permissions`** (`ERROR`) —
  instructions that turn off the sandbox or hand over blanket permissions
  (`--dangerously-skip-permissions`, `bypassPermissions`, `sandbox: false`,
  "grant all permissions", "allow all tools"). The rule keys on these concrete
  tokens rather than the prose phrase "disable the sandbox", because the engine
  docs legitimately discuss the sandbox — including doctrine that says never to
  disable it — and a prose match would fire on that. The prose case for the
  engine's own skills is already covered by `tests/doctrine.sh`; this rule
  extends a concrete net to all markdown.

- **`skill-content-destructive-shell`** (`ERROR`) — `chmod 777`, and `rm -rf`
  aimed at a filesystem root or home directory (`/`, `/*`, `~`, `$HOME`). The
  repo legitimately documents `rm -rf` of scoped temp and cache paths all over
  the engine docs, so the rule deliberately ignores those: it fires only when
  the target is root or home. `sudo` is gated only in its destructive form
  (`sudo rm -rf` of a dangerous root) — a bare `sudo apt-get` in an example is
  not a content footgun.

- **`skill-content-eval`** (`WARNING`) — `eval` on a string or command
  (`eval(`, `eval "..."`). `eval` executes arbitrary input and is a
  code-injection vector, but it also turns up in teaching and reference
  material, so this warns rather than fails. The regex is scoped to call-like
  syntax to avoid matching the words "evaluation" and "evals", which are common
  here.

- **`skill-content-unpinned-pip-install`** (`WARNING`) — a `pip install` with
  no version constraint. Unpinned installs are a reproducibility and
  supply-chain footgun, but they are a soft signal, so this warns. The
  `pattern-not-regex` carve-out skips lines that already pin a version
  (`==`, `>=`, etc.) or install editable/local/requirements targets.

## Path carve-outs

Two path exclusions apply to every rule:

- **`.semgrep/README.md`** — this file. It quotes the very patterns the rules
  match (you are reading them now), so without the carve-out it would trigger
  every rule against its own examples.
- **`**/examples/*/references/**`** — vendored upstream reference documentation.
  The engine fetches these files verbatim; they faithfully reproduce
  third-party install lines and code samples we neither author nor rewrite.
  Linting them as if they were our own guidance produces false positives (for
  example, an upstream tool's `curl ... | sh` installer), so they are out of
  scope. The rules still apply to the repository's own authored skill content.

## Adding a rule

1. Copy an existing rule in `skill-content.yml` and keep the shape:
   `id`, `message`, `severity`, `languages: [generic]`, and a `paths` block
   with the same two carve-outs.
2. Write the `message` for a contributor reading a failed check — say what the
   pattern is and why it matters for skill content specifically.
3. Run the ruleset against the whole tree before you settle on a severity:

   ```
   semgrep scan --config .semgrep/skill-content.yml .
   ```

   Read every hit. This repo intentionally documents dangerous commands (threat
   models, cleanup snippets, install instructions). If your rule fires `ERROR`
   on legitimate documentation, the build goes red on the next commit. Either
   down-rank it to `WARNING`, add a `pattern-not-regex` carve-out, or tighten
   the regex — then re-run until the tree is green at `ERROR`.
