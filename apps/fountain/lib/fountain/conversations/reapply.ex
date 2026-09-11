defmodule Fountain.Conversations.Reapply do
  @moduledoc """
  Re-selecting a conversation's Agent, Environment and Vault (#1565).

  A reapply keeps the conversation, its id, its transcript **and its machine**.
  What it changes is what the machine is configured with, on the machine that
  is already there. The disk survives, so an agent's cloned repositories,
  uncommitted work and build output are still where it left them.

  ## What updates in place, and what does not

  Most of a launch configuration is either process environment or a file, and
  both of those can be rewritten under a running sandbox. The reattach path
  has always done exactly this — `ConversationServer.do_reattach/6` rewrites
  `.mcp.json`, the `.env` file and the instructions on every wake — so this is
  an established mechanism rather than a new one.

  | Change | How it lands | Rebuild |
  |---|---|---|
  | Environment variables, Vault values | Respawn the runtime with fresh env | no |
  | System prompt, skills, MCP servers | Rewrite the files | no |
  | Model, permission policy | Per-turn arguments | no |
  | Runtime (claude to codex, say) | Adapter install | **yes** |
  | Packages, repositories, setup script | Install, clone, run | **yes** |
  | Network policy | Egress rules, written once at provision | **yes** |

  The rebuild rows are not stubbornness. The ACP adapter is an npm install
  that provisioning deliberately does *before* the network policy is applied,
  so installing a different one later fails in a way that reads as a protocol
  bug. `git clone` refuses a checkout that already exists, and a setup script
  that starts services fails on its second run, which is the same reason
  `Provisioning.discard_interrupted_attempt/3` exists.

  The network policy is the cautious one. `Egress.apply_policy/4` runs once,
  at provision, and nothing has ever re-run it against a live machine. Rather
  than assume it is idempotent and find out in production, a networking change
  is refused. Relaxing that is a one-line change to `fingerprint/1`, once
  somebody has shown the re-application is safe.

  This module is built across the #1565 stack. This first part is the digest
  alone: the rule that reads it lands next.
  """

  alias Fountain.Environments.Environment

  @doc """
  The digest of the Environment fields that provisioning turns into disk
  state. `nil` for no environment, which is itself a stable value to compare.

  Only the fields that shape the disk or the machine's network go in.
  Variables and the checkpoint are deliberately absent: a variable reaches a
  running machine on its next spawn, and the checkpoint only ever applies to a
  machine being built.
  """
  @spec fingerprint(Environment.t() | nil) :: String.t()
  def fingerprint(nil), do: "none"

  def fingerprint(%Environment{} = env) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {env.packages, env.repositories, env.setup_script, env.networking_type,
         env.networking_config}
      )
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
