# Recipe: distributing a finished contextualizer

A contextualizer only its author can load is a personal tool. This recipe
covers the two shapes that get one onto other engineers' machines — a
**skills-only plugin** published through the same marketplace mechanism the
engine itself ships on, and a **shared context repository** installed at user
level — and the one rule that governs both: a contextualizer must not register
a source its readers cannot already read.

Nothing here is a workflow. There is no `/skill-engine:distribute`; publishing
is a handful of deliberate gestures a maintainer makes, and this document is
the checklist for making them.

## Shape 1: a skills-only plugin

A repository that carries a plugin manifest and one or more contextualizer
skill directories. Claude Code installs it the way it installs any plugin, and
the consumer gets the navigator and its `references/` — nothing else.

### Layout

```
<area-domain>-contextualizer/
  .claude-plugin/
    plugin.json              # the manifest — see below
  skills/
    <slug>-context/          # the contextualizer, exactly as it sits in
      SKILL.md               #   .claude/skills/<slug>-context/ locally
      references/
      research/
  README.md
  CHANGELOG.md
```

The plugin root is the repository root, and the manifest lives at
`.claude-plugin/plugin.json` beneath it.

### The manifest

Start from
[`contextualizer-plugin.json.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/contextualizer-plugin.json.template)
and copy it to `.claude-plugin/plugin.json`. Two properties of that file are
the point of this shape, and both are easy to lose in a later edit.

**The manifest declares no hooks.** There is no `hooks` key, and adding one
changes what the artifact *is*: a contextualizer ships a navigator and
reference text, and nothing in it runs on a session event. A consumer who
installs a contextualizer is agreeing to load some documents, not to let a
third party execute code in every session they open. The engine's own
zero-hooks posture is the thing that makes it safe to install; a
contextualizer published out of it inherits that posture or forfeits it.

**The manifest does not enumerate the skills it ships.** Claude Code finds
them by convention — every directory under the plugin's own `skills/` is a
skill — so there is no `skills` key to keep in step with the directory. Ship
`skills/<slug>-context/` and the platform picks it up. Publishing a second
contextualizer out of the same repository is a second directory beside the
first and no manifest change at all.

The remaining fields are the ordinary ones, and
[04-delivery.md](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md)
§ Surface 2 covers each: `name` (match the skill slug — the namespace becomes
`/<plugin-name>:<skill-name>`), `version`, `description`, `author`,
`repository`, `license` (`UNLICENSED` is the honest choice for an
internal-only artifact), and `keywords`, which drive marketplace search.

### What a consumer runs

Two commands. The first registers the repository that carries your
`marketplace.json` as a marketplace; the second installs the plugin out of it.

```
/plugin marketplace add <your-org>/<your-org>-marketplace
/plugin install <area-domain>-context@<your-org>-marketplace
```

In a small org the plugin repository can be its own marketplace — add a
`.claude-plugin/marketplace.json` at its root listing one plugin, and
consumers add the plugin repository directly. In most orgs the marketplace is
a separate curated repository, and a maintainer copies each release's plugin
contents into it before consumers see anything. That cross-repo sync is the
single most common silent failure in this shape: you ship v1.0.1, never sync,
and everyone stays on v1.0.0 with no error. `04-delivery.md` § If your
marketplace is a separate repo walks the sync.

### How a REFRESH reaches consumers

As a new plugin version. A refresh changes reference files inside the
contextualizer; it does not reach anyone until the manifest's `version` is
bumped, the release is tagged, and the marketplace repository is synced to it.
Treat every refresh that a reviewer has applied as a patch or minor release
and ship it as one — a refresh that stays on `main` unreleased is a refresh
nobody downstream has.

Consumers update with `/plugin update`, which is unreliable per
[Issue #46594](https://github.com/anthropics/claude-code/issues/46594). Give
them the uninstall-then-reinstall pair in your README rather than letting them
assume the update path works.

## Shape 2: a shared context repository

One repository holding several contextualizers, installed at user level so
every session on the machine can reach them regardless of which project is
open. There is no plugin manifest and no marketplace in this shape — the
install is a clone.

### The layout the engine resolves

The engine's locator
([`shared/locator-block.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/shared/locator-block.md))
resolves two user-level roots:

- `~/.claude/skills/`
- `~/.claude/local/skills/`

At each one it runs `find "$root" -mindepth 1 -maxdepth 1 \( -type d -o
-type l \) -name '*-context'`. That is the whole contract: the
contextualizer directories must be the **immediate children of one of those
two roots**. Depth 1, nothing deeper — but a child may be a directory *or* a
symlink to one, which is what makes the second shape below work. A symlink
whose target no longer exists is skipped rather than reported as an
install.

Two ways to land them there, and both are fine:

- **Clone the repository *as* the root.** If the repository's top level is
  already a set of `<slug>-context/` directories, clone it to
  `~/.claude/skills/` itself (or to `~/.claude/local/skills/`, which leaves
  `~/.claude/skills/` free for per-machine installs). Every contextualizer
  lands at depth 1 by construction, and `git pull` is the update. Note that
  `git clone` refuses a destination directory that already exists and is
  non-empty — so this is the shape for a machine where the chosen root is
  fresh, and `~/.claude/local/skills/` is usually the one that is.
- **Clone it anywhere and symlink each contextualizer.** Keep the working
  copy wherever you keep repositories, then make one symlink per
  `<slug>-context/` into the root. This is the better shape when the
  repository holds anything besides contextualizers, or when a machine should
  carry only some of them — you symlink the three you want and leave the
  other forty alone.

### The trap

Cloning the repository **into** a subdirectory of either root — a plain `git
clone <url>` in `~/.claude/skills/`, which creates
`~/.claude/skills/<repo-name>/` — leaves every contextualizer at depth 2. The
user-level scan does not reach them, so nothing loads and nothing reports an
error either: an empty result is indistinguishable from having installed
nothing at all. If a freshly cloned repository's contextualizers are invisible,
this is the first thing to check.

(The engine does scan more deeply than depth 1 in one place — contextualizers
that sit beside the slice of a repository they describe, found under any
`.claude/skills/` below the *working repository's* root, to six levels,
skipping the directories a build or a package manager writes: `.git`,
`node_modules`, `vendor`, `target`, `dist`, `build`, `out`, `.next`, `.venv`,
`venv`, `__pycache__`, `.terraform`, `Pods`. That nested scan deliberately
skips the three fixed roots, so it is not a fallback that rescues a
mis-cloned user-level install.)

One more place the scan does not reach: a **Shape 1** plugin install lands
under `~/.claude/plugins/`, which is none of the three roots. Claude Code
loads those skills, but the engine's own workflows do not see them — so a
maintainer who dogfoods their own published plugin will find
`/skill-engine:status` does not list it. Work on the contextualizer in the
repository it is published from, or install it a second time by one of the
two shapes above.

## Which shape fits

| | Skills-only plugin | Shared context repository |
|---|---|---|
| **Choose it when** | The audience is wider than your team, the artifact is versioned, and you want an install a consumer can perform without being told where `~/.claude/` is | The audience is you and a handful of engineers who already clone repositories, and the contextualizers change often enough that release ceremony would be the bottleneck |
| **Install** | `/plugin marketplace add` + `/plugin install` | One clone, or one clone plus symlinks |
| **Update** | A new plugin version, synced to the marketplace | `git pull` |
| **Granularity** | Everything in the plugin, or nothing | Per-contextualizer, by which symlinks exist |
| **Cost** | A release gesture per refresh | Every consumer is trusted with the whole repository |

They are not exclusive. A common arrangement is a shared context repository as
the working copy for the maintainers, with the two or three contextualizers
that a wider audience needs also published as plugins.

## The rule both shapes share: scope access before you publish

**Do not register a source the intended audience cannot read.** A
contextualizer's references are derived from its sources, and they carry that
derivation with them: file paths, module names, API surfaces, the shape of a
schema, the names of internal services. Publish a contextualizer built over a
restricted repository and you have handed its structure to everyone who can
install the skill — without a review, without an access request, and without
anything in the artifact saying so.

This is not an engine check. The engine reads the paths you register and has
no way to compare them against an ACL it cannot see; the rule is enforced by
the maintainer who registers the source, at the moment they register it.

**The mitigation is per-domain contextualizers aligned to repository
permissions.** One contextualizer per access boundary, rather than one
contextualizer spanning several. If the billing service is restricted and the
platform libraries are not, they are two contextualizers with two audiences,
not one convenient index that has to be distributed at the most restrictive
permission either of them carries. Aligning the artifact to the boundary that
already exists is what lets the unrestricted half be shared freely.

Before publishing, read `research/source-paths.json` and ask of every entry:
can everyone who will be able to install this already read that? If the answer
is no for even one source, split the contextualizer or narrow the audience.

## Checklist

1. Every source in `research/source-paths.json` is readable by the intended
   audience.
2. `verify.sh` passes on the contextualizer.
3. For a plugin: `.claude-plugin/plugin.json` exists, has no `hooks` key, has
   no `skills` key, and its `version` is the one you are about to tag.
4. For a plugin: the marketplace repository is synced to this release.
5. For a shared repository: the contextualizer directories are the immediate
   children of `~/.claude/skills/` or `~/.claude/local/skills/` on a test
   machine, and `/skill-engine:status` lists them.
