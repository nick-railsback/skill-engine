# skill-engine (plugin)

**Teach Claude your codebase. Keep it taught.**

You're reading this because you installed the plugin. Here's what just happened:

- The engine's commands are now available under `/skill-engine:` — scaffold (`engine-bootstrap`), propose (`discover`, `refresh`, `new-reference`), review and promote (`review`, `apply`, `discard`), and inspect or maintain (`self-audit`, `status`, `clean-cache`, `config-set`), plus the `using-skill-engine` router.
- On first bootstrap, the engine may ask whether to pre-clone referenced repos into `~/.cache/skill-engine/`. It defaults to **No**. The engine works without the cache; pre-cloning is purely an optimization, though highly recommended.
- The engine never auto-applies a change by default. Every proposed edit surfaces for review.

**Next step:** `/skill-engine:engine-bootstrap https://github.com/<your-org>/<your-repo>`

**For the why behind the engine** — see the [project README](https://github.com/nick-railsback/skill-engine/blob/main/README.md).
**For the full path** — see the [quickstart](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/quickstart.md).
**For the load-bearing decisions** — see the [doctrine](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/doctrine.md).
