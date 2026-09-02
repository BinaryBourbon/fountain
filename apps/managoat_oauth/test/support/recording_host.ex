defmodule Managoat.OAuth.Host.Recording do
  @moduledoc """
  A `Managoat.OAuth.Host` that records what the library asked of it.

  Every callback runs in the process that called the instance function (the
  library spawns nothing), so each one sends itself to `self()` and a test
  reads it back with `assert_received`. Tokens are `"tok-" <> subject`, so a
  test can tell whose token it got without a table of them.

  Two dials, per process, for the ordering rules the state machine keeps:
  `refuse_subject/1` makes `subject_allowed?/1` answer `{:error, reason}`,
  and `fail_issue/1` makes `issue_token/3` answer `{:error, reason}`, until
  `reset/0`. Process-local, so async tests cannot see each other's dials.
  """
  @behaviour Managoat.OAuth.Host

  @subject_key {__MODULE__, :subject}
  @issue_key {__MODULE__, :issue}

  @doc "Refuse every subject from now on, in this process."
  @spec refuse_subject(atom()) :: :ok
  def refuse_subject(reason) do
    Process.put(@subject_key, {:error, reason})
    :ok
  end

  @doc "Fail every mint from now on, in this process."
  @spec fail_issue(term()) :: :ok
  def fail_issue(reason) do
    Process.put(@issue_key, {:error, reason})
    :ok
  end

  @doc "Back to accepting and minting."
  @spec reset() :: :ok
  def reset do
    Process.delete(@subject_key)
    Process.delete(@issue_key)
    :ok
  end

  @impl true
  def subject_allowed?(subject) do
    send(self(), {:subject_allowed?, subject})
    Process.get(@subject_key, :ok)
  end

  @impl true
  def issue_token(subject, grant, opts) do
    send(self(), {:issue_token, subject, grant, opts})

    case Process.get(@issue_key) do
      nil -> {:ok, %{access_token: "tok-" <> subject, token: %{subject: subject, grant: grant}}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def audit(event, meta, opts) do
    send(self(), {:audit, event, meta, opts})
    :ok
  end
end
