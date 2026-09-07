defmodule Fountain.Conversations.CodexSandbox do
  @moduledoc false

  # Sprites gives its non-root user ambient capabilities. Codex's bubblewrap
  # refuses to run with those capabilities. Clearing both sets before exec
  # also clears permitted/effective capabilities in the adapter and its children.
  # Keep the bounding set and sudo available for approved privileged commands;
  # this repairs the launch environment without changing Codex's sandbox policy.
  def command(:sprites, "codex", cmd, args) do
    {"/usr/bin/setpriv", ["--inh-caps=-all", "--ambient-caps=-all", "--", cmd | args]}
  end

  def command(_provider, _runtime, cmd, args), do: {cmd, args}
end
