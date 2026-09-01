# Managoat.Substitution

`${VAR}` substitution over a nested config value: eager, escapable, and
every missing key reported at once.

```elixir
Managoat.Substitution.apply("hello ${NAME}", %{"NAME" => "world"})
#=> {:ok, "hello world"}

Managoat.Substitution.apply(%{"headers" => %{"Authorization" => "Bearer ${TOKEN}"}}, %{})
#=> {:error, {:missing_vars, ["TOKEN"]}}
```

| Syntax | Result |
|---|---|
| `${VAR}` | the value of `VAR` in the map |
| `$${VAR}` | the literal text `${VAR}` |
| `$$` | the literal `$` |

Identifiers match `[A-Z_][A-Z0-9_]*`. `apply/2` walks maps and lists and
rewrites string leaves only. When any referenced key is missing the whole
value is returned unchanged inside the error, never half-substituted.

## Where it comes from

This is the first library extracted from [Fountain](https://github.com/BinaryBourbon/fountain)
under [ADR 0037](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0037-component-libraries.md).
Fountain uses it at sandbox provision time for an agent's `mcp_servers`
config. The `fountain` CLI carries a Go implementation of the same syntax
(`cli/internal/substitution`); the two are kept behaviourally aligned and
the CLI's tests are the second implementation's contract.

## Licence

Apache-2.0. See `LICENSE`.
