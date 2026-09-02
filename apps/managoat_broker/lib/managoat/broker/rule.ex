defmodule Managoat.Broker.Rule do
  @moduledoc """
  One rule of a session: requests to hosts matching `pattern` get this
  credential, in this shape.

  The host defines what a rule is *for* (a tenant's binding, a catalog
  default, an allowed host under `deny`) and maps it to one of these at
  session creation. The proxy sees only the struct, with the credential
  already resolved to its value: nothing here names a key in some other
  store.

  ## Patterns

  `host[:port][/path]`. The host may be a `*.example.com` wildcard (matching
  subdomains, not the apex) and the path a prefix, with a trailing `*`
  matching the rest. A port pins the request's port; without one any port
  matches. Matching is case-insensitive on the host and ignores the query.

  ## Schemes

  | `scheme` | fields | effect on a matched request |
  |---|---|---|
  | `:bearer` | `credential` (binary) | `Authorization: Bearer <credential>` replaces any `Authorization` header |
  | `:basic` | `credential` (`{username, password}`) | `Authorization: Basic base64(username:password)` |
  | `:api_key` | `header` (default `Authorization`), `prefix` (default `""`), `credential` (binary) | `<header>: <prefix><credential>` replaces that header |
  | `:custom` | `template` (`%{header => "text {{ KEY }}"}`), `credential` (`%{"KEY" => value}`) | each header rendered from its template; a `{{ KEY }}` with no value is left as written |
  | `:substitute` | `placeholder`, `credential` (binary) | every header *value* has each occurrence of `placeholder` replaced by `credential`; sets no header itself |
  | `:passthrough` | none | the request is forwarded untouched; under `deny` this is how a host is allowed |

  `:substitute` is the shape for a credential the agent addresses itself
  (an inference key the runtime sends as `x-api-key`, or as a bearer, in
  a placeholder it was handed): the proxy does not need to know the header,
  only the placeholder. It reaches headers only, never the path, query or
  body, which is one of the deviations from Agent Vault the README lists.

  Several rules may match one request. The first matched rule that sets a
  header is the one that does; every matched `:substitute` rule applies.
  """

  @type scheme :: :bearer | :basic | :api_key | :custom | :substitute | :passthrough

  @type t :: %__MODULE__{
          name: String.t() | nil,
          pattern: String.t(),
          scheme: scheme(),
          credential: term(),
          header: String.t() | nil,
          prefix: String.t(),
          template: %{String.t() => String.t()},
          placeholder: String.t() | nil
        }

  @enforce_keys [:pattern, :scheme]
  defstruct [
    :name,
    :pattern,
    :scheme,
    :credential,
    :header,
    :placeholder,
    prefix: "",
    template: %{}
  ]
end
