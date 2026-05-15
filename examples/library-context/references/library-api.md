# Library Public API

Flask's public API for building web applications has three shapes that show up in nearly every program: the application object (the WSGI callable), the routing layer (decorator-driven URL → view binding), and the request/response wrappers (the per-request data carriers). The Blueprint object is the modular packaging of routes; once you understand the application object, blueprints are the same shape applied to a sub-tree of routes. The wrappers are thin Werkzeug subclasses that add Flask-specific conveniences without changing the underlying contract.

## Contents

* When to Use This Reference
* Architecture Overview
* Critical Patterns (route binding, response shapes, request data, blueprints)
* Common Gotchas
* Key Components
* Edge cases and deeper investigation
* Related References

## When to Use This Reference

Use this reference when working with:
* defining routes with `@app.route(...)` or `@blueprint.route(...)`
* reading request data: query string, form fields, JSON body, headers
* building responses: returning strings, dicts, tuples, `Response` objects
* organizing larger apps with `Blueprint` and `register_blueprint(...)`
* the differences between Flask's `Request`/`Response` and the underlying Werkzeug classes

If the question is about writing a Flask extension or about the `init_app(...)` authoring pattern, prefer [library-plugins](library-plugins.md) instead.

## Architecture Overview

A Flask app is one `Flask` instance plus zero or more `Blueprint` objects registered against it. The instance is the WSGI callable a server invokes per request; the blueprints contribute routes, error handlers, and lifecycle hooks. Per request, Flask binds a `Request` (Werkzeug subclass) to the request context and invokes the view function bound to the matched route. The view returns a value; Flask coerces it to a `Response` (also a Werkzeug subclass) and the WSGI server writes it back.

```text
WSGI server -> Flask(app) ----+---> Blueprint A (routes)
                              |
                              +---> Blueprint B (routes)
                              |
                              +---> request_context: bind Request
                              |
                              v
                          view function -> Response
```

The `Request` and `Response` wrappers are subclasses of Werkzeug's wrappers ([`Request as RequestBase`](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/wrappers.py#L7-L8)); they add Flask-aware conveniences (e.g., `request.json`, view-routing attributes) without overriding the WSGI contract. The `Blueprint` class is itself a thin sync subclass of a sansio `Blueprint` definition ([blueprints.py#L18-L51](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/blueprints.py#L18-L51)) — the IO-aware shim adds the Click CLI group; the route-registration semantics live in the sansio base.

## Critical Patterns

### Pattern 1: Route binding via decorator

Bind a URL to a view function with `@app.route(rule, methods=...)`. The decorator is a thin wrapper around `add_url_rule(...)`, which is what you'd call directly when registering a route programmatically (e.g., from a class-based view or a plugin).

```python
from flask import Flask

app = Flask(__name__)

@app.route("/users/<int:user_id>", methods=["GET"])
def get_user(user_id):
    return {"id": user_id}
```

The path converter syntax (`<int:user_id>`, `<string:slug>`, etc.) is Werkzeug's; Flask passes the rule through. Default converter is `string` (no slashes).

### Pattern 2: Returning a response

A view can return a `str`, a `dict` (auto-jsonified), a tuple `(body, status)` or `(body, status, headers)`, or a fully constructed `Response` object. The response coercion logic is in `make_response(...)`; rely on it for the common case and reach for explicit `Response(...)` only when you need to set things the tuple form can't carry (e.g., streaming, custom mimetype on a non-JSON body).

```python
@app.route("/health")
def health():
    return {"status": "ok"}, 200
```

### Pattern 3: Reading request data

Read query-string values from `request.args`, form fields from `request.form`, JSON body from `request.get_json()` (or `request.json` for the cached property). The `Request` class adds `view_args` (the path-converter outputs) and `url_rule` ([wrappers.py#L18-L52](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/wrappers.py#L18-L52)) so introspection of the matched route is available inside the view.

### Pattern 4: Blueprints for modular routing

Group related routes into a `Blueprint`, register the blueprint on the application. The blueprint can carry its own URL prefix, subdomain, error handlers, and CLI commands.

```python
from flask import Blueprint

bp = Blueprint("users", __name__, url_prefix="/users")

@bp.route("/<int:user_id>")
def show(user_id): ...

app.register_blueprint(bp)
```

A `Blueprint` is just a deferred recorder of route registrations; nothing happens until `register_blueprint(...)` plays the recording back against the live app. This deferral is what makes blueprints composable — you can build them at module import time without needing the app to exist yet.

## Common Gotchas

* **Path converters default to `string`, which excludes slashes.** A naive route like `/files/<path>` won't match `/files/a/b.txt`; you need `<path:filename>` to match path segments containing slashes.
* **`request.json` returns `None` if the `Content-Type` is wrong.** Flask requires `Content-Type: application/json` (or one of the JSON variants) before it parses the body. If a client sends raw JSON without the header, `request.get_json(force=True)` overrides; `request.json` does not.
* **A view returning `None` raises a TypeError.** Return at minimum an empty string `""` to produce a valid 200 OK response — `None` is not a value `make_response` will coerce.
* **Blueprint URL prefixes don't compose recursively.** A blueprint registered with `url_prefix="/v1"` does not stack with a parent blueprint's prefix; Flask's blueprint nesting model is shallow. To get nested prefixes, set them explicitly at registration time.
* **`MAX_CONTENT_LENGTH` defaults to `None`.** No payload size limit is enforced unless you set it; large uploads can OOM the worker if you don't configure it ([wrappers.py#L57-L86](https://github.com/pallets/flask/blob/22d924701a6ae2e4cd01e9a15bbaf3946094af65/src/flask/wrappers.py#L57-L86)).

## Key Components

* **`flask.Flask`**: the application class; `Flask(__name__)` builds the WSGI callable. Defined in `src/flask/app.py`.
* **`flask.Blueprint`**: modular route packaging. Defined in `src/flask/blueprints.py`.
* **`flask.Request`**: per-request data carrier. Werkzeug subclass with Flask-specific attributes (`view_args`, `url_rule`).
* **`flask.Response`**: the response wrapper. Werkzeug subclass with Flask defaults for mimetype.
* **`flask.request`**: the request-context proxy; access from inside a view to read the active request.

## Edge cases and deeper investigation

* If the question lands on an unusual converter or rule pattern not covered above, you may `Read` or `Grep` into Flask's `src/flask/sansio/` directly — the URL-matching contract lives in the sansio layer, with `src/flask/blueprints.py` as the IO shim on top.
* If a request appears to silently drop data (e.g., form fields missing), check `MAX_CONTENT_LENGTH`, `MAX_FORM_MEMORY_SIZE`, and `MAX_FORM_PARTS` in the app config; the per-request setters on `Request` override them when set.
* If routes registered via a blueprint don't appear at runtime, confirm `app.register_blueprint(bp)` ran and the bound URL prefix is what you expect — `app.url_map` lists every active rule.

## Related References

* [library-plugins](library-plugins.md) — when a question is about writing or registering an extension rather than calling the API directly.
