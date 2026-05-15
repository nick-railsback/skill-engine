---
name: library-context
description: "Answers questions about the Flask library ecosystem. Use when working with Flask request/response handling, routing, blueprints, extensions, or extension authoring."
---

# Library Context Navigator

## Overview

Flask is a Python web framework for building HTTP applications. This navigator catalogs the primary subsystems Flask developers ask questions about and points at on-demand reference files in `references/`. The navigator itself stays small (under 100 lines); references load only when relevant to the current question.

When asked a Flask question:
1. Scan the **Catalog** below for the matching topic.
2. Follow the link to read the reference file.
3. If the question spans multiple subsystems, consult the **Cross-reference map**.
4. If a reference points at a Flask source-repo URL for deeper detail, follow it only if the reference itself didn't answer the question.

## Catalog

| Reference | Description |
|---|---|
| [library-api](references/library-api.md) | Public API surface: routing, request/response objects, blueprints, view functions |
| [library-plugins](references/library-plugins.md) | Extension lifecycle, the `init_app()` authoring contract, registration patterns |

## Cross-reference map

* **Routing or request-handling questions** start at `library-api`. It covers route decorators, blueprints, and the `Request`/`Response` wrappers.
* **Extension authoring or "how do I write a plugin"** start at `library-plugins`. It covers the deferred-initialization (`init_app()`) pattern and the extension registry.
* **Questions that span both** (e.g., "how does an extension hook into request teardown?") read `library-plugins` first, then follow the cross-link into `library-api` for the request-lifecycle background.

## Instructions to Claude

When loading a reference file, the path syntax depends on the platform:

* **Claude Code**: Read the reference using the platform-provided skill-directory variable:
  `Read $CLAUDE_SKILL_DIR/references/library-<topic>.md`

* **Claude Desktop**: Read the reference using a relative path; the platform resolves it from the skill's installed location:
  `Read references/library-<topic>.md`

Loading rules:
* Load one reference at a time unless the Cross-reference map says to load both.
* If the primary reference doesn't fully answer the question, follow any source-repo URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the primary reference says to.
* If the user's question is clearly out of scope for Flask (e.g., a question about a different web framework), don't invoke this skill at all.

## Progressive Disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via SHA-pinned source-repo URLs.

When a reference includes a source-repo URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream Flask source is the long tail.
