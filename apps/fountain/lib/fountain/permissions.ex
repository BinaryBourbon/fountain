defmodule Fountain.Permissions do
  @moduledoc """
  What answers `session/request_permission`, per tool.

  Gate 3 of [0014](decisions/0014-agent-client-protocol.md), built in #939.

  Every runtime Fountain ships used to run with its safety rail removed by a
  vendor flag. Three of those four flags went with the legacy spawn path
  (#671-#675); what replaced them was this module's predecessor — a constant in
  `ACP.Peer` that answered every request by picking `allow_always`, else
  `allow_once`, else whatever was offered first. The rail was still off, but it
  was off in one function we own, which is what made it a policy problem rather
  than a fork-four-CLIs problem.

  ## The shape

  A policy is a map of tool name to verdict, plus a `"default"` key:

      %{"default" => "auto_allow", "Bash" => "auto_deny"}

  Tool names are matched the way the transcript labels them
  (`ACP.Blocks.tool_name/1`): the agent's own `title`, falling back to ACP's
  coarse `kind`. So a policy key is the string a user reads on a tool card,
  not an internal id.

  ## Narrow, never widen

  An agent holds a policy; a launch may supply its own. **The launch may only
  make the policy more restrictive.** That single rule is the no-escalation
  guarantee, and it is why there is no `allowed_permission_policies` list beside
  it the way `environment_id` needs `allowed_environment_ids` — a launch cannot
  reach anything the agent did not already permit, so there is nothing to
  allow-list.

  It is enforced twice, deliberately:

  - `check_narrows/2` rejects a widening launch **at the door**, so the caller
    gets an error naming the tool rather than a silent downgrade.
  - `effective/2` **clamps** — the result is the more restrictive of the two for
    every tool. This is the invariant the peer actually depends on, and it means
    an agent that tightens its policy later also tightens every conversation
    already running under it. Storing a pre-merged policy on the conversation
    would have frozen the old, looser one.

  ## Verdicts

  | verdict | what answers |
  |---|---|
  | `auto_allow` | today's behaviour: `allow_always`, else `allow_once`, else the first option offered |
  | `auto_deny` | a `reject_*` option when the agent offered one, `cancelled` when it did not |
  | `ask` | a human. **Not built** — see #940; rejected at the door until it is |

  `auto_allow` is the default, so adopting a policy changes nothing until
  someone writes one.

  ## Never synthesise an option

  `auto_deny` picks from what the agent offered and never invents an id. An
  adapter that offers no rejection gets `cancelled`, which is the protocol's own
  "no option was selected" and the only honest answer available. Inventing an
  `optionId` the agent never advertised would at best error and at worst select
  something unrelated.
  """

  @auto_allow "auto_allow"
  @ask "ask"
  @auto_deny "auto_deny"

  @verdicts [@auto_allow, @ask, @auto_deny]

  # Restrictiveness, low to high. `effective/2` takes the max, `check_narrows/2`
  # requires the launch to be >= the agent. `ask` sits between the two because
  # it withholds the tool until a human acts, which is stricter than allowing
  # and looser than refusing outright.
  @rank %{@auto_allow => 0, @ask => 1, @auto_deny => 2}

  @default_key "default"

  @doc "Every verdict a policy may name."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The verdict applied when a policy names neither the tool nor a default."
  @spec default_verdict() :: String.t()
  def default_verdict, do: @auto_allow

  @doc """
  Verdicts that can be honoured today.

  `ask` is a valid policy value with nowhere to ask: #940 builds the stream
  event and the answer endpoint. Until then it is refused where a policy is
  written, rather than degrading to an allow (unsafe) or hanging the turn
  forever (worse — see the note on the ceiling in 0014 gate 3).
  """
  @spec buildable_verdicts() :: [String.t()]
  def buildable_verdicts, do: [@auto_allow, @auto_deny]

  @doc "Whether `verdict` can be honoured today. False for `ask` until #940."
  @spec buildable?(String.t()) :: boolean()
  def buildable?(verdict), do: verdict in buildable_verdicts()

  @doc """
  The verdict `policy` gives `tool`.

  Falls back to the policy's own `"default"`, then to `auto_allow`.
  """
  @spec verdict_for(map() | nil, String.t() | nil) :: String.t()
  def verdict_for(policy, tool) when is_map(policy) do
    with nil <- tool && Map.get(policy, tool),
         nil <- Map.get(policy, @default_key) do
      @auto_allow
    else
      verdict when verdict in @verdicts -> verdict
      # A value that is not a verdict is not trusted into an allow: the
      # changesets reject these, so reaching here means the row was written
      # around them.
      _ -> @auto_deny
    end
  end

  def verdict_for(_policy, _tool), do: @auto_allow

  @doc """
  Merge an agent's policy with a launch's, taking the **more restrictive** of
  the two for every tool either of them names.

  Clamping rather than replacing is what makes the launch override safe by
  construction: no merge can produce a verdict looser than the agent's, whatever
  was stored, and a later tightening of the agent applies to conversations
  already running.
  """
  @spec effective(map() | nil, map() | nil) :: map()
  def effective(agent_policy, launch_policy) do
    agent_policy = normalize(agent_policy)
    launch_policy = normalize(launch_policy)

    agent_policy
    |> keys_with(launch_policy)
    |> Map.new(fn key ->
      {key, stricter(verdict_for(agent_policy, key), verdict_for(launch_policy, key))}
    end)
    |> Map.put(
      @default_key,
      stricter(verdict_for(agent_policy, nil), verdict_for(launch_policy, nil))
    )
  end

  @doc """
  Whether `launch` is at least as restrictive as `agent` for every tool.

  Returns `:ok`, or `{:error, {:permission_policy_widens, tool}}` naming the
  first tool the launch would loosen. The check spans the union of both key
  sets *and* the defaults, because a launch that only lowers `"default"` still
  loosens every tool the agent covered by its own default.
  """
  @spec check_narrows(map() | nil, map() | nil) ::
          :ok | {:error, {:permission_policy_widens, String.t()}}
  def check_narrows(agent, launch) do
    agent = normalize(agent)
    launch = normalize(launch)

    agent
    |> keys_with(launch)
    |> Enum.concat([@default_key])
    |> Enum.find_value(:ok, fn key ->
      if rank(verdict_for(launch, key)) < rank(verdict_for(agent, key)) do
        {:error, {:permission_policy_widens, key}}
      end
    end)
  end

  @doc """
  The `session/request_permission` result for `params` under `policy`.

  Returns the inner `outcome` object — the caller wraps it, because ACP's
  response body is `{"outcome": {"outcome": …}}`.
  """
  @spec outcome(map() | nil, map()) :: map()
  def outcome(policy, params) when is_map(params) do
    options = Map.get(params, "options") || []

    case verdict_for(normalize(policy), tool_name(params)) do
      @auto_deny -> deny(options)
      # `ask` cannot reach here: it is refused where a policy is written, and
      # clamping never invents it. Denying is the safe reading if it ever does.
      @ask -> deny(options)
      _ -> allow(options)
    end
  end

  @doc """
  The tool a permission request is about, as the transcript labels it.

  Mirrors `ACP.Blocks.tool_name/1` so a policy key is the string a user reads on
  the tool card. `nil` when the request carries no tool call at all, which falls
  through to the policy's default.
  """
  @spec tool_name(map()) :: String.t() | nil
  def tool_name(%{"toolCall" => call}) when is_map(call) do
    case {call["title"], call["kind"]} do
      {title, _} when is_binary(title) and title != "" -> title
      {_, kind} when is_binary(kind) and kind != "" -> kind
      _ -> nil
    end
  end

  def tool_name(_params), do: nil

  @doc "Which verdict of the two withholds more."
  @spec stricter(String.t(), String.t()) :: String.t()
  def stricter(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  defp rank(verdict), do: Map.get(@rank, verdict, @rank[@auto_deny])

  # Every tool either side names, minus the default — which is handled
  # separately because it is a fallback, not a tool.
  defp keys_with(a, b) do
    a
    |> Map.keys()
    |> Enum.concat(Map.keys(b))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == @default_key))
  end

  defp normalize(policy) when is_map(policy), do: policy
  defp normalize(_), do: %{}

  # Today's ladder, kept verbatim: `allow_always`, else `allow_once`, else
  # whatever was offered first. That last rung is why this is parity and not a
  # new behaviour — an adapter offering only bespoke option kinds is answered
  # exactly as it was before #939.
  defp allow(options) do
    select(options, ~w(allow_always allow_once)) || selected(List.first(options)) || cancelled()
  end

  # No such rung on the deny side. Falling back to "whatever was offered first"
  # would pick an *allow* on any adapter that lists its options that way, which
  # is the one thing `auto_deny` must never do. An adapter that offers no
  # rejection gets `cancelled` — the protocol's own "nothing was selected".
  defp deny(options) do
    select(options, ~w(reject_always reject_once)) || cancelled()
  end

  defp select(options, kinds) do
    Enum.find_value(kinds, fn kind ->
      options |> Enum.find(&(is_map(&1) and &1["kind"] == kind)) |> selected()
    end)
  end

  defp selected(%{"optionId" => id}), do: %{outcome: "selected", optionId: id}
  defp selected(_), do: nil

  defp cancelled, do: %{outcome: "cancelled"}
end
