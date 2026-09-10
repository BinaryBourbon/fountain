defmodule Fountain.Conversations.DetachedRequest do
  @moduledoc """
  A permission request that outlived its turn (#1635): its deadline, and the
  prompt that carries its answer back to the agent.

  ## Why there is a second shape of request at all

  The `ask` verdict was built for an LLM blocked mid-thought
  (`Fountain.Conversations.Pending`). The request is held inside a running
  turn, and the turn holding it defers idle reclaim, so the wait has to end
  well inside the idle bound or the sandbox is destroyed by the max-lifetime
  ceiling rather than parked (0014 gate 3, 0017).

  A deterministic operation waits on something else. "Approve this production
  apply", "confirm the DNS delegation landed", "sign off these deletes" take
  hours or days, and nothing in the sandbox needs to run while they do. So the
  agent sends `session/request_permission` and then answers `session/prompt`
  with the `waiting` stop reason. The turn ends `completed` with `waiting:
  true` on its row, the request stays `pending`, the conversation goes `idle`
  and the sandbox parks on the usual bound.

  ## What the agent gets back

  The old peer cannot carry the answer. The sandbox may be suspended, and the
  `session/request_permission` JSON-RPC id died with the connection that
  raised it. So the answer opens a **new turn** whose `session/prompt` is one
  line of JSON, and nothing else:

      {"fountain/permission_answer":{"request_id":"7.1f0c…","tool":"Bash",
       "outcome":"answered","option_id":"allow","answered_at":"2026-09-07T…Z"}}

  `outcome` is `answered` or `timeout`. `option_id` is the option the answerer
  picked, or the rejection the expiry chose from the agent's own list, and is
  null where the agent offered no rejection at all (the protocol's
  `cancelled`). The agent decides what to do with it.

  One line of JSON in the prompt rather than a `_meta` field on
  `session/prompt` because `Managoat.ACP.Peer.prompt/3` takes text and images
  and offers no hook for protocol extensions. The map is the shape a `_meta`
  key would carry, under the same name, so the day the peer grows one this
  becomes a move rather than a redesign.

  ## The deadline

  In seconds:

  1. `_meta.fountain.timeout` on the `session/request_permission` params;
  2. `ask_timeout` in the effective permission policy
     (`Fountain.PermissionPolicy`);
  3. the global `:permission_ask_timeout_seconds` ceiling, five minutes by
     default.

  Where 1 and 2 are both set the **shorter** wins: 1 is written inside the
  sandbox and 2 is the tenant's, so the agent bounds its own wait and cannot
  extend the tenant's. Either alone is honoured, and neither leaves 3.

  Only a detached request reads 1 and 2. A request held inside a running turn
  keeps the global ceiling, which still has to sit under the idle bound.
  """

  alias Fountain.Conversations.Lifecycle
  alias Managoat.ACP.Permissions

  @answer_key "fountain/permission_answer"

  @doc "The `_meta` key an answer travels under, in both directions."
  @spec answer_key() :: String.t()
  def answer_key, do: @answer_key

  @doc """
  The per-request timeout in seconds, from the `session/request_permission`
  params, or nil.

  Read from `_meta.fountain.timeout`. A value that is not a positive number of
  seconds reads as nil, so a typo falls back to the policy rather than
  becoming "deny at once" or "never deny".
  """
  @spec timeout_seconds(map() | nil) :: pos_integer() | nil
  def timeout_seconds(%{"_meta" => %{"fountain" => %{"timeout" => value}}}),
    do: positive_seconds(value)

  def timeout_seconds(_params), do: nil

  @doc """
  How long this request waits once it has detached, in milliseconds.

  `params` is the request's own `session/request_permission` params (nil when
  none reached us) and `policy_seconds` the effective `ask_timeout`.

  **The shorter of the two, where both are set.** The request comes from
  inside the sandbox and the policy comes from the tenant, so letting the
  request name the longer one would let an agent hold a tool open for days
  against a policy that said minutes. Either alone is honoured; neither
  leaves the global ceiling.
  """
  @spec timeout_ms(map() | nil, pos_integer() | nil) :: pos_integer()
  def timeout_ms(params, policy_seconds) do
    case {timeout_seconds(params), policy_seconds} do
      {nil, nil} -> Lifecycle.ask_timeout_ms()
      {request, nil} -> request * 1000
      {nil, policy} -> policy * 1000
      {request, policy} -> min(request, policy) * 1000
    end
  end

  @doc """
  The `session/request_permission` a relayed `acp` line carries, as
  `{request_id, params}`, or nil.

  The peer reports a held request's tool and its options, not the params they
  came from, and the per-request timeout rides in `_meta`. It persists the
  line immediately before it reports the ask, and under the **minted** request
  id, so the owner can keep the last one and match it by id rather than assume
  it. Decoded only for a line that names the method, so an ordinary turn's
  thousands of updates pay a substring search and nothing else.
  """
  @spec request_line(String.t(), binary()) :: {term(), map()} | nil
  def request_line("acp", data) do
    if String.contains?(data, "session/request_permission") do
      case Managoat.ACP.Protocol.classify_line(data) do
        {:request, id, "session/request_permission", params} -> {id, params}
        _ -> nil
      end
    end
  end

  def request_line(_stream, _data), do: nil

  @doc "The kept `request_line/2` pair's params, when it is this request's."
  @spec params_for({term(), map()} | nil, term()) :: map() | nil
  def params_for({id, params}, request_id) when id == request_id, do: params
  def params_for(_kept, _request_id), do: nil

  @doc "When a request raised now, waiting `timeout_ms`, is denied."
  @spec deadline(pos_integer(), DateTime.t()) :: DateTime.t()
  def deadline(timeout_ms, now \\ DateTime.utc_now()) do
    now |> DateTime.add(timeout_ms, :millisecond) |> DateTime.truncate(:second)
  end

  @doc """
  Whether the agent offered `option_id` for this request.

  The fail-closed rule the in-turn path applies in the peer, applied here
  where no peer is left to apply it: an option Fountain never saw the agent
  offer is refused rather than relayed.
  """
  @spec offered?(map(), String.t()) :: boolean()
  def offered?(request, option_id) do
    request
    |> options()
    |> Enum.any?(&(is_map(&1) and &1["optionId"] == option_id))
  end

  @doc """
  The option id a denial picks, or nil.

  `Managoat.ACP.Permissions.deny_outcome/1` chooses from the agent's own
  list — a `reject_*` where it offered one, and the protocol's `cancelled`
  where it did not. Never an option the agent did not send.
  """
  @spec deny_option_id(map()) :: String.t() | nil
  def deny_option_id(request) do
    case request |> options() |> Permissions.deny_outcome() do
      %{optionId: id} -> id
      _ -> nil
    end
  end

  @doc """
  The `session/prompt` text that carries a resolution back to the agent.

  One line, one JSON object, the shape at the top of this module.
  """
  @spec resume_prompt(map(), String.t(), String.t() | nil) :: String.t()
  def resume_prompt(request, outcome, option_id) do
    Jason.encode!(%{
      @answer_key => %{
        "request_id" => request["request_id"],
        "tool" => request["tool"],
        "outcome" => outcome,
        "option_id" => option_id,
        "answered_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc "A pending request as a client reads it, from the turn row that holds it."
  @spec to_json(map(), map()) :: map()
  def to_json(request, turn) do
    %{
      request_id: request["request_id"],
      tool: request["tool"],
      options: options(request),
      asked_at: request["asked_at"],
      deadline: turn.permission_deadline,
      turn_id: turn.id
    }
  end

  defp options(%{"options" => options}) when is_list(options), do: options
  defp options(_request), do: []

  defp positive_seconds(n) when is_integer(n) and n > 0, do: n

  defp positive_seconds(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp positive_seconds(_n), do: nil
end
