---
name: modelcontextprotocol-python-sdk-auth
description: "OAuth 2.1 authentication in the MCP Python SDK. Server-side: `TokenVerifier` protocol, `OAuthAuthorizationServerProvider`, `AuthSettings`, bearer-token middleware, and the resource-server vs. authorization-server modes. Client-side: `OAuthClientProvider` with PKCE, `TokenStorage` interface, callback flow."
---

# MCP Python SDK — OAuth authentication

MCP servers and clients use OAuth 2.1 with PKCE for HTTP-based transports. This SDK supplies both halves:

- **Server side**: `mcp.server.auth` — a `TokenVerifier` protocol for resource servers, an `OAuthAuthorizationServerProvider` interface for full authorization servers, bearer-token middleware that gates request handlers, and `AuthSettings` carried on the `MCPServer` constructor.
- **Client side**: `mcp.client.auth` — `OAuthClientProvider` is an `httpx.Auth` that drives the authorization-code-with-PKCE flow, with a `TokenStorage` you implement for persistence.

Top-level signatures: server in [`src/mcp/server/auth/`](https://github.com/modelcontextprotocol/python-sdk/tree/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth), client in [`src/mcp/client/auth/`](https://github.com/modelcontextprotocol/python-sdk/tree/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/auth).

## Server: resource-server mode (token verifier)

The simplest server-side mode: your MCP server is a Resource Server (RS) per [RFC 9728](https://datatracker.ietf.org/doc/rfc9728/). It accepts bearer tokens issued by an external authorization server. You implement only `TokenVerifier` (a Protocol with one async method):

```python
from pydantic import AnyHttpUrl
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.mcpserver import MCPServer


class MyTokenVerifier(TokenVerifier):
    async def verify_token(self, token: str) -> AccessToken | None:
        # Validate against your authorization server (introspection,
        # JWT signature check, cached lookup, etc.). Return None to reject.
        introspection_data = await self.introspect(token)  # your call
        return AccessToken(
            token=token,
            client_id=introspection_data["client_id"],
            scopes=introspection_data.get("scope", "").split(),
            expires_at=introspection_data.get("exp"),
            resource=introspection_data.get("aud"),  # RFC 8707
            subject=introspection_data.get("sub"),   # RFC 7662 — resource owner
            claims=introspection_data,                # full introspection dict
        )


mcp = MCPServer(
    "Weather Service",
    token_verifier=MyTokenVerifier(),
    auth=AuthSettings(
        issuer_url=AnyHttpUrl("https://auth.example.com"),
        resource_server_url=AnyHttpUrl("http://localhost:3001"),
        required_scopes=["user"],
    ),
)
```

`AuthSettings` ([`src/mcp/server/auth/settings.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/settings.py)) carries:

- `issuer_url: AnyHttpUrl` — the authorization server URL that issues your tokens.
- `resource_server_url: AnyHttpUrl | None` — this MCP server's URL, used as the resource identifier and for the OAuth Protected Resource Metadata document.
- `required_scopes: list[str] | None` — scopes a token must carry.
- `service_documentation_url`, `client_registration_options`, `revocation_options` — additional `AS` mode options (see below).

With `token_verifier=` set, `MCPServer` installs `BearerAuthBackend` and `RequireAuthMiddleware` automatically. Requests without a valid bearer token return 401; requests with insufficient scopes return 403.

Full example: [`examples/snippets/servers/oauth_server.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/oauth_server.py).

## Server: authorization-server mode (full provider)

If your MCP server *is* the authorization server (issuing its own tokens, handling `/authorize` and `/token` routes, supporting dynamic client registration per [RFC 7591](https://datatracker.ietf.org/doc/rfc7591/)), implement `OAuthAuthorizationServerProvider[AuthCodeT, RefreshTokenT, AccessTokenT]`. The provider interface (in [`src/mcp/server/auth/provider.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/provider.py)) requires methods covering the lifecycle: `get_client`, `register_client`, `authorize`, `load_authorization_code`, `exchange_authorization_code`, `load_refresh_token`, `exchange_refresh_token`, `load_access_token`, `revoke_token`.

Pass `auth_server_provider=` (instead of `token_verifier=`) to `MCPServer(...)`. The provider's typed errors (`RegistrationError`, `AuthorizeError`, `TokenError`) carry the OAuth `error` code Literal types — return these from your provider methods rather than raising arbitrary exceptions; the framework maps them to spec-compliant error responses.

`AuthorizationCode`, `RefreshToken`, and `AccessToken` (all in [`src/mcp/server/auth/provider.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/provider.py)) each carry an optional `subject: str | None` — the resource owner (RFC 7662/9068 `sub`). Propagate it across the flow: set it on the `AuthorizationCode` you return from `authorize`, copy it into the `AccessToken` returned from `exchange_authorization_code`, and forward it on refresh. `AccessToken` additionally carries `claims: dict[str, Any] | None` for extra introspection claims (e.g. `iss`, `act`). The `subject` is unique only per issuer, not globally.

For a full reference server, see the [`examples/servers/simple-auth/`](https://github.com/modelcontextprotocol/python-sdk/tree/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/servers/simple-auth) directory in the SDK.

## Server: bearer middleware internals

The middleware lives at [`src/mcp/server/auth/middleware/`](https://github.com/modelcontextprotocol/python-sdk/tree/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/middleware). The components:

- **`BearerAuthBackend`** — a Starlette `AuthenticationBackend` that extracts the `Authorization: Bearer <token>` header, calls your `TokenVerifier`/provider's `load_access_token`, and stashes the result.
- **`RequireAuthMiddleware`** — checks scopes against `AuthSettings.required_scopes` and returns 401/403 on miss.
- **`AuthContextMiddleware`** — exposes the authenticated `AccessToken` to your tool/resource/prompt handlers via the request context.
- **`get_access_token() -> AccessToken | None`** (in [`auth_context.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/middleware/auth_context.py)) — the helper your handlers call to read the current request's token. Returns `None` for unauthenticated requests. Use `get_access_token().subject` for the resource owner, `.client_id` for the OAuth client, `.scopes` for granted scopes, `.claims` for the full introspection payload. **Do not use `Context.client_id`** from `mcp.server.mcpserver` for OAuth identity — that property reads from MCP `_meta` params, not the bearer token (see [mcpserver reference](modelcontextprotocol-python-sdk-mcpserver.md)).

You don't normally interact with these directly — they're wired by `MCPServer.__init__` when you supply `auth=...`.

## Client: OAuthClientProvider

The client-side provider is an `httpx.Auth` implementation that drives the authorization-code-with-PKCE flow. You implement `TokenStorage` (`get_tokens`, `set_tokens`, `get_client_info`, `set_client_info`) and supply callbacks for the redirect (showing the user the auth URL) and the callback (parsing the redirect URL the user pastes back).

```python
from mcp.client.auth import OAuthClientProvider, TokenStorage
from mcp.shared.auth import OAuthClientInformationFull, OAuthClientMetadata, OAuthToken

class InMemoryTokenStorage(TokenStorage):
    def __init__(self):
        self.tokens: OAuthToken | None = None
        self.client_info: OAuthClientInformationFull | None = None

    async def get_tokens(self) -> OAuthToken | None: return self.tokens
    async def set_tokens(self, tokens: OAuthToken) -> None: self.tokens = tokens
    async def get_client_info(self) -> OAuthClientInformationFull | None: return self.client_info
    async def set_client_info(self, info: OAuthClientInformationFull) -> None: self.client_info = info

async def handle_redirect(auth_url: str) -> None:
    print(f"Visit: {auth_url}")

async def handle_callback() -> tuple[str, str | None]:
    callback_url = input("Paste callback URL: ")
    params = parse_qs(urlparse(callback_url).query)
    return params["code"][0], params.get("state", [None])[0]

oauth = OAuthClientProvider(
    server_url="http://localhost:8001",
    client_metadata=OAuthClientMetadata(
        client_name="My MCP Client",
        redirect_uris=[AnyUrl("http://localhost:3000/callback")],
        grant_types=["authorization_code", "refresh_token"],
        response_types=["code"],
        scope="user",
    ),
    storage=InMemoryTokenStorage(),
    redirect_handler=handle_redirect,
    callback_handler=handle_callback,
)
```

Attach it to an `httpx.AsyncClient(auth=oauth)` and pass that into `streamable_http_client(url, http_client=...)`:

```python
async with httpx.AsyncClient(auth=oauth, follow_redirects=True) as client:
    async with streamable_http_client(url, http_client=client) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            ...
```

Full pattern: [`examples/snippets/clients/oauth_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/clients/oauth_client.py).

## URL-mode elicitation (the auth pivot)

For tools that need user authorization mid-request (the user is in a chat session and your tool needs to open a browser tab for them to confirm), use URL-mode elicitation. From the server side:

```python
from mcp.shared.exceptions import UrlElicitationRequiredError
from mcp.types import ElicitRequestURLParams

@mcp.tool()
async def connect_service(service_name: str, ctx: Context) -> str:
    elicitation_id = str(uuid.uuid4())
    raise UrlElicitationRequiredError([
        ElicitRequestURLParams(
            mode="url",
            message=f"Authorization required to connect to {service_name}",
            url=f"https://{service_name}.example.com/oauth/authorize?elicit={elicitation_id}",
            elicitation_id=elicitation_id,
        )
    ])
```

The framework converts the raise into a `-32042` JSON-RPC error response. The client's elicitation callback receives the URL, opens it in a browser, and the user completes the flow out-of-band. See [`examples/snippets/clients/url_elicitation_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/clients/url_elicitation_client.py).

## Token storage in production

The in-memory `TokenStorage` in the docs example is **demo code only**. For production:

- Persist tokens to OS-level secure storage (Keychain on macOS, Credential Manager on Windows, libsecret on Linux).
- Implement refresh handling — `OAuthClientProvider` automatically refreshes when `get_tokens` returns a token whose `expires_at` is near; your storage must round-trip the new token from `set_tokens`.
- Encrypt at rest if you must use the filesystem.

The `OAuthToken` and `OAuthClientInformationFull` types are in [`src/mcp/shared/auth.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/shared/auth.py).

## Documentation status

The upstream `docs/authorization.md` page is currently a "Under Construction" stub. The authoritative source is the code (`mcp.server.auth`, `mcp.client.auth`) plus the example servers. This reference summarizes the surface area you can rely on at SHA `3eb57994`; expect [`docs/authorization.md`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/docs/authorization.md) to grow before v2 ships.
