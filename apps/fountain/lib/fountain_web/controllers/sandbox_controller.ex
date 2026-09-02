defmodule FountainWeb.SandboxController do
  @moduledoc """
  The caller's sandboxes — the machines their conversations run on.

  A sandbox is created by `POST /api/conversations` and reused by passing its
  id back as `sandbox_id` (ADR 0023 gate 3); this is where a client learns
  which machines it has, and which conversations are on each. The one write
  is `DELETE /api/sandboxes/:id`, which resets a persistent home (#1071).

  Two more are a look inside a ready machine: `POST …/exec` runs a
  command and waits, `GET …/files` reads one file. The rules — ready only,
  no wake, allowed mid-turn, capped, audited by size — are
  `Fountain.Conversations.SandboxCommands`'s.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.SandboxCommands
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Sandboxes"])

  operation(:index,
    summary: "List sandboxes",
    description:
      "Every sandbox the caller has provisioned, newest first, each with the conversations " <>
        "on it and which of them is mid-turn. `status` filters by a comma-separated list; " <>
        "without it every status is listed, terminated ones included.",
    parameters: [
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated: pending, starting, ready, suspended, terminated, failed."
      ]
    ],
    responses: [
      ok: {"Sandboxes", "application/json", Schemas.SandboxListResponse},
      bad_request: {"Unknown status", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user

    with {:ok, statuses} <- parse_statuses(params["status"]) do
      render(conn, :index, sandboxes: Conversations.list_sandboxes(user.id, status: statuses))
    end
  end

  operation(:show,
    summary: "Get a sandbox",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Sandbox", "application/json", Schemas.SandboxResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_sandbox_with_conversations(id, user.id) do
      nil -> {:error, :not_found}
      sandbox -> render(conn, :show, sandbox: sandbox)
    end
  end

  operation(:delete,
    summary: "Reset a sandbox",
    description:
      "Destroy a persistent sandbox — the agent's home — so the next launch on the same " <>
        "agent, environment and vault builds a clean machine. The conversations on it are " <>
        "kept, idle; each one's next prompt lands on the fresh home. Only a `persistent` " <>
        "sandbox that is not `terminated` or `failed` resets (`422 sandbox_not_resettable`), " <>
        "and not while any conversation on it is mid-turn (`409 sandbox_mid_turn`).",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Reset",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"A conversation on it is mid-turn", "application/json", Schemas.Error},
      unprocessable_entity: {"Not a live persistent sandbox", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # Ownership: the scoped get_sandbox establishes it; reset_sandbox trusts
    # the row it is handed.
    with %Sandbox{} = sandbox <- Conversations.get_sandbox(id, user.id) || {:error, :not_found},
         {:ok, _} <- Conversations.reset_sandbox(sandbox, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:exec,
    summary: "Run a command on a sandbox",
    description:
      "Run one command on a `ready` sandbox the caller owns and wait for it. Arguments go " <>
        "as separate words — nothing is shell-parsed; run `bash -lc` yourself for a pipeline. " <>
        "The answer carries stdout and stderr interleaved, the exit code, the duration, and " <>
        "whether the output was cut at 1 MB. A suspended sandbox is not woken " <>
        "(`409 sandbox_not_ready`): a prompt wakes it. A conversation mid-turn does not " <>
        "block the call — reading the tree while the agent works is the point — so a " <>
        "command that changes the tree changes it under the agent, exactly as a prompt " <>
        "could. Full-scope keys only; a sandbox's own token gets 403. Audited as " <>
        "`sandbox.exec` with sizes and the exit code, never the command or the output.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Command", "application/json", Schemas.SandboxExecRequest, required: true},
    responses: [
      ok: {"Result", "application/json", Schemas.SandboxExecResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"Not ready", "application/json", Schemas.Error},
      bad_gateway: {"The sandbox did not run it", "application/json", Schemas.Error},
      gateway_timeout: {"It did not finish in time", "application/json", Schemas.Error}
    ]
  )

  def exec(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    body = conn.body_params

    with %Sandbox{} = sandbox <- Conversations.get_sandbox(id, user.id) || {:error, :not_found},
         {:ok, result} <-
           SandboxCommands.exec(
             sandbox,
             body["command"],
             body["args"] || [],
             Audited.attribution(conn, cwd: body["cwd"], timeout_ms: body["timeout_ms"])
           ) do
      json(conn, %{data: result})
    end
  end

  operation(:file,
    summary: "Read a file from a sandbox",
    description:
      "One file's bytes from a `ready` sandbox the caller owns, as `application/octet-stream`. " <>
        "At most 4 MB; a longer file is cut and the answer carries `X-Fountain-Truncated: true`. " <>
        "`404 file_not_found` when nothing is at the path, `422 not_a_file` for a directory " <>
        "or an unreadable entry. Ready-only, no wake, allowed mid-turn, full scope — the " <>
        "same rules as `POST /api/sandboxes/:id/exec`. Audited as `sandbox.file_read` with " <>
        "the size, never the path or the bytes.",
    parameters: [
      id: [in: :path, type: :string, required: true],
      path: [
        in: :query,
        type: :string,
        required: true,
        description: "An absolute path on the sandbox."
      ]
    ],
    responses: [
      ok:
        {"The bytes", "application/octet-stream",
         %OpenApiSpex.Schema{type: :string, format: :binary}},
      not_found: {"No sandbox, or no file", "application/json", Schemas.Error},
      conflict: {"Not ready", "application/json", Schemas.Error},
      unprocessable_entity: {"Not a file", "application/json", Schemas.Error}
    ]
  )

  def file(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    path = params["path"]

    with :ok <- absolute(path),
         %Sandbox{} = sandbox <- Conversations.get_sandbox(id, user.id) || {:error, :not_found},
         {:ok, bytes, truncated} <-
           SandboxCommands.read_file(sandbox, path, Audited.attribution(conn)) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("x-fountain-truncated", to_string(truncated))
      |> send_resp(200, bytes)
    end
  end

  defp absolute("/" <> _ = path) when byte_size(path) < 4096, do: :ok
  defp absolute(_), do: {:error, "invalid_path"}

  defp parse_statuses(nil), do: {:ok, nil}
  defp parse_statuses(""), do: {:ok, nil}

  defp parse_statuses(raw) when is_binary(raw) do
    statuses = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if statuses != [] and Enum.all?(statuses, &(&1 in Sandbox.statuses())),
      do: {:ok, statuses},
      else: {:error, "invalid_status"}
  end
end
