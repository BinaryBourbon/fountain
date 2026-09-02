# Managoat.Broker

An egress credential proxy for sandboxed agents. The sandbox holds a
**placeholder** where a credential used to be, plus a proxy address with a
session token in it. Every outbound HTTP request goes through this proxy,
which looks the token up in a session store the host implements, gets back
the rules the host prepared for that session, and attaches the real
credential to each request that matches one. The agent process never holds
the credential; the proxy is the only host it may reach, so a placeholder
is worthless off the box.

```elixir
# The host's supervision tree:
children = [
  {Managoat.Broker,
   port: 14322,
   store: MyApp.BrokerSessions,        # a Managoat.Broker.Store
   ca_seed: MyApp.broker_ca_seed(),    # 32 bytes, the same on every replica
   allow_private_upstreams: false}
]

# The sandbox's environment, prepared by the host:
#   HTTPS_PROXY=http://<token>:<label>@broker.example.com:14322
#   GITHUB_TOKEN=__github_token__
# and the root from Managoat.Broker.ca_pem/0 in its trust store.
```

## What the proxy does

One plaintext HTTP listener (TLS toward the sandbox, if any, is the
ingress's job) speaking the two things a forward proxy speaks:

- **`CONNECT host:443`** for HTTPS. The proxy opens the upstream TLS
  connection first (an unreachable or untrusted origin is a `502` before any
  tunnel exists), answers `200`, then completes a TLS handshake with the
  *sandbox* using a leaf certificate for that host signed by the listener's
  own CA. Inside the tunnel it reads each request head, rewrites the headers
  per the session's rules, and forwards head and body to the origin. Bytes
  coming back are relayed untouched and unparsed, so a streaming model reply
  streams. Keep-alive works; every request on the tunnel is rewritten. A
  WebSocket upgrade is injected like any other request, after which the
  tunnel is a byte pipe.
- **Absolute-form requests** (`GET http://host/path`) for plain HTTP, one
  request per connection.

The client authenticates with `Proxy-Authorization: Basic
base64(token:label)`, which is what an HTTP client sends for a proxy URL
with userinfo. The token is looked up once per client connection (the unit
a sandbox's HTTP client pools on); `proxy-authorization` never reaches the
origin. A missing, unknown or expired token is `407`.

Two guards protect the operator's network and the tenant's intent:

- **SSRF.** An origin that resolves to a private, loopback, link-local
  (including the cloud metadata address), CGNAT or unspecified IPv4 address
  is refused with `403` before any connection, and the dial goes to the
  vetted address rather than the name, so a rebinding DNS answer between
  check and dial changes nothing. `allow_private_upstreams: true` turns the
  guard off for a test rig whose origins are on localhost.
- **`deny`.** A session whose `unmatched_host_policy` is `:deny` refuses a
  host no rule names at `CONNECT`, before a tunnel or handshake exists, and
  refuses a request no rule matches inside a tunnel with `403`. That is how
  an allowlist is enforced: one `:passthrough` rule per allowed host.

## The `Store` behaviour

```elixir
@callback lookup(token :: binary()) :: {:ok, Managoat.Broker.Session.t()} | :error
```

That is all the proxy needs at request time: the raw token in, a session
with its rules (credentials already resolved) out. Creating, releasing and
sweeping sessions are the host's business; they touch its tables and its
key hierarchy, and the proxy never needs any of it. Hashing the token
before storing it is the host's choice inside `lookup/1`; the library
passes the raw token from the header.

A store with several instances (one per listener in a test) implements
`lookup/2` instead and is configured as `store: {Module, instance}`.
`Managoat.Broker.Store.Memory` is the reference store, an `Agent` holding a
map, for the library's tests and for a consumer without a database.

A `Managoat.Broker.Session` has `rules`, `unmatched_host_policy`
(`:passthrough` or `:deny`), `expires_at` and an opaque `meta` map the host
fills for its own logging. A `Managoat.Broker.Rule` has a `pattern`
(`host[:port][/path]`, wildcards allowed), a `scheme` and the fields the
scheme needs:

| `scheme` | fields | effect on a matched request |
|---|---|---|
| `:bearer` | `credential` | `Authorization: Bearer <credential>` replaces any `Authorization` |
| `:basic` | `credential` as `{username, password}` | `Authorization: Basic base64(username:password)` |
| `:api_key` | `header` (default `Authorization`), `prefix`, `credential` | `<header>: <prefix><credential>` |
| `:custom` | `template` (`%{header => "text {{ KEY }}"}`), `credential` (`%{"KEY" => value}`) | each header rendered from its template |
| `:substitute` | `placeholder`, `credential` | every header value has the placeholder replaced by the credential |
| `:passthrough` | none | forwarded untouched; under `deny`, how a host is allowed |

The first matched rule that sets a header does; every matched `:substitute`
rule applies to the header values.

## The child spec

`{Managoat.Broker, port: 14322, store: Module, ca_seed: <32 bytes>,
allow_private_upstreams: false}`. Every option but the last is required,
and a missing one raises at start naming the option. Optional:
`upstream_ssl_options` (merged over the `:ssl` options the proxy dials
origins with; a test origin's `cacerts`) and `name` (default
`Managoat.Broker`, for several listeners in one VM). There is no
configuration module reading an otp_app: the listener is started by the
host with values the host computed at boot, and a library that is not
started serves nothing.

Once up: `Managoat.Broker.port/1`, `running?/1` and `ca_pem/1`.

## The CA

A brokered sandbox trusts one root, and the proxy presents a leaf for each
host the sandbox `CONNECT`s to, signed by that root. Every replica of the
host must present leaves the sandbox trusts, whichever one the ingress
hands a connection to, and a sandbox that survived a restart must still
trust what a fresh replica signs. So the root is not generated and stored:
it is **derived** from the 32-byte `ca_seed` with HKDF-SHA256, reduced into
P-256's scalar field, and the certificate's subject, serial and validity
are fixed, so every replica computes the same key, subject and serial from
the same seed. Rotating the seed rotates the CA; nothing else does.

The root's self-signature bytes vary per derivation, because ECDSA signing
is randomised, so two replicas' PEMs differ byte for byte. That is
harmless: a client matches a trust anchor by subject and public key and
never verifies a root's own signature. `ca_test.exs` proves a leaf signed
after a re-derivation chains to the first root.

The seed is the host's to derive, and it must not be a key the host uses
for anything else: derive it from a master key with a fixed info string,
so the CA key is never the storage key. Leaves live thirty days, are cached
per host in an ETS table the listener owns, and are re-signed after
twenty-nine.

## Telemetry

Every request the proxy decides about emits `[:managoat, :broker,
:request]` with `%{count: 1}` and the metadata `method`, `host`, `path`,
`outcome` (`:injected`, `:passthrough` or `:denied`), `rule` (the matched
rule's name, or nil) and `meta` (the session's, unchanged). Never a header,
never a body. The host attaches a handler and writes its log line with
whatever `meta` carries; the library logs only refusals, which have no
session to attribute.

## Deviations from Agent Vault

This proxy replaced Infisical's Agent Vault behind the same interface. The
parity suite (`test/managoat/broker/agent_vault_parity_test.exs`) replays
the upstream tests it stands in for and lists what was not ported. In
short:

- **Absolute-form (plain HTTP) is one request per connection.** The proxy
  adds `Connection: close` upstream and closes after the response. HTTPS
  tunnels keep-alive normally. Plain HTTP through the proxy is apt and
  little else.
- **No path, query or body substitution.** The `:substitute` rule reaches
  header values only, which covers an inference key a runtime sends as a
  bearer or an `x-api-key` in a placeholder it was handed. A credential a
  client puts in a URL is not brokered.
- **No WebSocket frame rewriting.** The upgrade request is injected; the
  frames after it are piped as bytes.
- **No auth-failure rate limiting** on the proxy port.
- **No body-size caps** (Agent Vault's response cap was unlimited by
  default too).
- **No IPv6 upstreams.** The proxy resolves IPv4 only.
- **The label half of the proxy credential is not checked.** Agent Vault
  refused a valid token presented with another vault's name. Here the
  random per-session token is the whole binding; the label exists because
  some clients (git) refuse a proxy URL with a user and no password.

## Two operational traps a host must handle

Both were found in production with the previous broker and are about the
sandbox and the ingress, not the proxy, so this library cannot fix them.

- **`sudo` strips the proxy environment.** A sandbox that runs `sudo
  apt-get` loses `HTTPS_PROXY` and the rest, and the install fails against
  a closed network with an error naming apt, not the proxy. Provisioning
  has to keep the proxy variables across `sudo` (`Defaults env_keep` in a
  sudoers drop-in).
- **An unknown CA leaf, and a shared-NAT peer.** A sandbox that does not
  trust the root sees every brokered host fail TLS with an "unknown
  issuer" error the tool attributes to the origin. The root has to reach
  the operating system trust store (`update-ca-certificates`) and the
  toolchains that carry their own roots (`NODE_EXTRA_CA_CERTS` for Node,
  `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`/`CARGO_HTTP_CAINFO` pointed at the
  full system bundle, `UV_NATIVE_TLS`) before anything else runs. The same
  incident's other half was a per-IP auth rate limiter at the vendor's
  proxy port tripping on many sandboxes behind one NAT address; this proxy
  has none, so nothing in front of it needs to allow for that.

## Licence

Apache-2.0. See `LICENSE`.
