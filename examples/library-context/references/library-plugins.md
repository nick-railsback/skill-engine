# Library Extensions

Flask's extension model is straightforward but subtle: a Flask extension is a small Python package that exposes a class with an `init_app(app)` method. The class can be instantiated without an app (so import-time wiring works), and only at `init_app` time does it bind to a specific Flask instance. This **deferred-init** pattern is what lets a single extension cleanly support multiple Flask apps in the same process and what makes extension authoring composable with the application-factory pattern.

## Contents

* When to Use This Reference
* Architecture Overview
* Critical Patterns (two-step class, per-app state, CLI commands, teardown handlers)
* Common Gotchas
* Key Components
* Edge cases and deeper investigation
* Related References

## When to Use This Reference

Use this reference when working with:
* writing a new Flask extension and choosing where to put `init_app(...)` setup
* using existing extensions (`flask-login`, `flask-sqlalchemy`, etc.) and understanding their initialization shape
* registering teardown handlers, request hooks, or CLI commands from inside an extension
* the extension registry on a Flask app and what's stored in `app.extensions`

If the question is about the request/response API itself or about routing without an extension layer, prefer [library-api](library-api.md) instead.

## Architecture Overview

A Flask extension is a class that holds extension-level state and a method `init_app(app)` that wires that state to a specific Flask instance. The two-step shape — instantiate without an app at module scope, then call `init_app(app)` against the live application — is the contract every well-behaved extension follows.

```text
extension module      Flask app
+------------------+  +----------------------+
| ext = Ext()      |  | app = Flask(__name__)|
| (no app yet)     |  |                      |
+--------+---------+  +------+---------------+
         |                   |
         |  ext.init_app(app)|
         +------------------>+
                             |
                             v
                  app.extensions["ext-name"] = state
                  app.before_request(...)
                  app.teardown_appcontext(...)
                  app.cli.add_command(...)
```

The Flask instance carries an `extensions` dict — defined on the application object in `src/flask/app.py` — that extensions populate with their per-app state. Hook registration uses the same public API user code calls (`@app.before_request`, `@app.teardown_appcontext`, `app.cli.add_command(...)`); the only thing that makes "extension code" different from "user code" is convention, not mechanism.

The Blueprint surface ([blueprints.py#L18-L51](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/blueprints.py#L18-L51)) is sometimes used by extensions that want to package their own routes (e.g., an admin extension that ships a UI). When an extension registers a blueprint, it does so during `init_app(app)` against the live app, not at module scope.

## Critical Patterns

### Pattern 1: The two-step extension class

```python
class MyExt:
    def __init__(self, app=None):
        # No-app construction is the common case for app-factory users.
        if app is not None:
            self.init_app(app)

    def init_app(self, app):
        # Per-app wiring. Must be safe to call multiple times across apps.
        app.extensions["myext"] = {"config": app.config.get("MYEXT_KEY")}

        @app.before_request
        def _on_request():
            # request-level setup
            ...

        @app.teardown_appcontext
        def _teardown(exc):
            # cleanup; runs on every app context teardown
            ...
```

The `__init__` accepting a `None` app is the load-bearing part: it lets users do `ext = MyExt()` at module scope and call `ext.init_app(app)` later, when the app is ready (e.g., inside a `create_app()` factory). Without this, the extension can't compose with the factory pattern.

### Pattern 2: Storing per-app state under `app.extensions`

Use a unique string key for your extension under `app.extensions[...]`. The naming convention is the package name lowercased with hyphens replaced by underscores. Don't overwrite an existing key; if you support being called twice on the same app, idempotently update the existing dict.

### Pattern 3: Registering a CLI command from an extension

Extensions can extend the `flask` CLI by adding a command to either the application's CLI group or a blueprint's CLI group. The extension's `init_app` is the right place for this; doing it at module scope risks adding the command before the app's command groups exist.

```python
import click

@click.command("myext-status")
def status_command():
    click.echo("ok")

class MyExt:
    def init_app(self, app):
        app.cli.add_command(status_command)
```

### Pattern 4: Teardown handlers run on every request, even on error

A teardown handler registered with `app.teardown_appcontext` is invoked unconditionally — including when the view raised an exception. The handler receives the exception (or `None` on success). Use this for resource cleanup that must run regardless of view outcome (e.g., closing a database session).

## Common Gotchas

* **Calling `init_app` twice on the same Flask instance silently re-registers hooks.** Flask doesn't dedupe `before_request` or `teardown_appcontext` registrations. If your extension is called twice (e.g., by a misconfigured factory), every request runs the hook twice. Guard against re-init by checking `app.extensions.get("myext")` and bailing if already present.
* **Module-scope `init_app` doesn't compose with the factory pattern.** A common mistake is `ext = MyExt(app)` at module top with `app = Flask(__name__)` also at module top. This works for one app but breaks the moment a user wants two apps in one process. The two-step `MyExt() → init_app(app)` shape is the safe default.
* **`app.extensions` is a regular dict, not thread-safe state.** It's fine for setup, but per-request state belongs on `g` (the request-context proxy), not in `app.extensions`. Mixing the two is a common source of "it worked in dev, broke in prod under concurrency."
* **Blueprints registered by extensions still need a URL prefix.** If your extension ships a blueprint, choose whether to register it with a default `url_prefix` or accept one from app config. Hard-coding a prefix in the extension is a footgun for users who already have a route at the same path.
* **CLI commands registered before `init_app` is called won't appear.** If you decorate a function with `@app.cli.command(...)` at module scope and then defer `init_app`, the command won't be visible until the extension wires up. Register CLI commands inside `init_app` for predictability.

## Key Components

* **`init_app(app)`**: the per-app wiring entry point. Must be idempotent.
* **`app.extensions`**: the dict where extensions register their per-app state. String keys, dict values.
* **`app.before_request(...)`**, **`app.teardown_appcontext(...)`**, **`app.errorhandler(...)`**: the public hooks an extension registers against during `init_app`.
* **`app.cli.add_command(...)`**: how an extension contributes to the `flask` CLI.
* **Blueprint authoring** ([blueprints.py#L18-L51](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/blueprints.py#L18-L51)): for extensions that ship routes.

## Edge cases and deeper investigation

* If you are debugging an extension that "isn't running" on a request, check `app.extensions` to confirm the extension actually registered. A silent `init_app` failure (e.g., a swallowed `KeyError` reading config) is the most common cause.
* If the extension needs to know about app-level config that isn't set yet at `init_app` time, defer reads with `current_app.config[...]` inside the request hook — `current_app` is bound only during request handling, but that's where the value is needed anyway.
* If an extension wants to wrap the WSGI middleware around the app, set `app.wsgi_app = MyMiddleware(app.wsgi_app)` inside `init_app`. This composes correctly with other middleware as long as each extension follows the same pattern.

## Related References

* [library-api](library-api.md) — for questions about the routing, request, or response APIs the extension hooks into.
