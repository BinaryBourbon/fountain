defmodule Managoat.Runtimes.Quirks do
  @moduledoc """
  Every workaround Fountain carries on a runtime's behalf, the defect that
  justifies it, and the condition under which it is deleted.

  ## Why a registry rather than comments

  The comments already exist, and they are good ones — `Managoat.Runtimes.ACP`
  spends forty lines on how gemini's session store erases a session in the act
  of loading it, and `Managoat.Runtimes.Claude` explains exactly why MCP
  servers go in as files. Both end with some version of "delete this when
  upstream lands."

  Nothing checks that. A workaround outliving its defect is invisible: it
  keeps working, so no test fails and no user complains, and the cost shows up
  only as the next person reasoning about a system that is stranger than it
  needs to be. Worse is the version where the upstream fix lands and the
  workaround now *conflicts* with it — the case
  `Managoat.Runtimes.Claude`'s moduledoc already anticipates, where a fixed
  session-scoped channel plus our file-based provisioning would register every
  MCP server twice.

  So each entry names the code that implements it as an MFA, and
  `quirks_test.exs` asserts that function still exists. Delete the workaround
  without the entry and the test fails; leave an entry pointing at code that
  is gone and the test fails. The registry cannot silently rot, which is the
  only property that makes it worth more than the comments.

  ## What is not a quirk

  A runtime doing something *unusual* is not a quirk. codex delivering its
  credential through `codex login --with-api-key` rather than
  `OPENAI_API_KEY` looks like one and is not: that is codex's documented auth
  mechanism, no upstream fix would remove it, and there is no condition under
  which we stop doing it. It belongs to the irreducible tier described in
  `Managoat.Runtimes`. The test for a quirk is whether you can state what
  would have to change for the code to be deleted. If you cannot, it is not a
  workaround — it is just how that runtime works.

  ## Re-probing

  `reprobe` says how to find out whether the defect is still there. It is the
  checklist for a version bump: when the claude adapter pin moves, the
  question "does `session/new`'s `mcpServers` launch stdio servers yet?" has
  a known answer procedure, and if the answer changed the entry says what to
  delete.
  """

  @typedoc """
  `upstream` is a URL, or `{:none, reason}` for a workaround with no upstream
  to track — one we carry because of a decision on our own side, usually the
  sprite base image.
  """
  @type quirk :: %{
          id: atom(),
          runtimes: [String.t()],
          summary: String.t(),
          why: String.t(),
          upstream: String.t() | {:none, String.t()},
          measured_against: String.t(),
          implemented_by: {module(), atom(), arity()},
          reprobe: String.t(),
          delete_when: String.t()
        }

  @quirks [
    %{
      id: :claude_mcp_via_files,
      runtimes: ["claude"],
      summary: "claude's MCP servers are provisioned as files, not sent over ACP",
      why: """
      ACP defines a session-scoped channel for MCP servers (`session/new`'s
      `mcpServers`) and `Managoat.ACP.Peer` sends the agent's servers
      there correctly. claude-agent-acp never launches stdio servers passed
      that way, so the session-scoped path delivers nothing. We write a
      project `.mcp.json` plus `enableAllProjectMcpServers` instead, which the
      CLI picks up through its `settingSources`.
      """,
      upstream: "https://github.com/agentclientprotocol/claude-agent-acp/issues/883",
      measured_against: "claude-agent-acp 0.66–0.70, reproduced standalone",
      implemented_by: {Managoat.Runtimes.Claude, :write_config, 2},
      reprobe: """
      Run a conversation with an MCP server declared on the agent, with
      `write_config/2` stubbed out, and check the model can call an
      `mcp__<server>__*` tool. If it can, the session-scoped path works.
      """,
      delete_when: """
      `session/new`'s `mcpServers` launches stdio servers. Then drop
      `Claude.write_config/2` in the same PR that confirms it — leaving both
      paths on registers every server twice, which is the failure
      `Managoat.Runtimes.Gemini` already had and fixed by writing to one
      place only.
      """
    },
    %{
      id: :gemini_session_store_consolidation,
      runtimes: ["gemini"],
      summary: "Fountain rewrites gemini's private chat store after every turn",
      why: """
      gemini's `session/load` builds a fresh config on the same session id
      before looking the session up, and that config's chat recorder takes its
      new-session branch: it appends a `$set` carrying only its
      `<session_context>` bootstrap to the file it is about to read. gemini's
      own reader treats `$set.messages` as a replacement, so loading a session
      erases it — permanently, not just for that turn. `SessionStore`
      consolidates the chats directory at the end of every turn: keep the file
      with real content, delete the poisoned duplicates, park the survivor
      under a timestamp the recorder cannot produce.
      """,
      upstream: "https://github.com/google-gemini/gemini-cli/issues/28775",
      measured_against: "gemini-cli 0.53.0 through 0.56.0, verified live in both directions",
      implemented_by: {Managoat.Runtimes.Gemini.SessionStore, :install, 1},
      reprobe: """
      Five consecutive turns inside one wall-clock minute with the consolidation
      disabled. The collision is bucketed by minute, so spacing turns out hides
      it — that is what made the original bug look random.
      """,
      delete_when: """
      `session/load` stops appending a `$set` that replaces the transcript it
      is loading. Delete `Managoat.Runtimes.Gemini.SessionStore`, its call in
      `Gemini.prepare_sandbox/3`, the per-turn `consolidate/2` call, and the
      mechanism section of `Managoat.Runtimes.ACP`'s moduledoc.
      """
    },
    %{
      id: :opencode_absent_from_base_image,
      runtimes: ["opencode"],
      summary: "opencode is installed into every sandbox at provision time",
      why: """
      opencode does not ship in the sprite base image, so the first session on
      a new sandbox pays a `bun install -g opencode-ai` plus a symlink onto
      PATH — 10–30s the other runtimes do not pay. It is also the one runtime
      we cannot version-pin this way, since the install takes whatever is
      current.
      """,
      upstream: {:none, "a sprite base-image decision on our side, not a defect in opencode"},
      measured_against: "sprite base image as of 2026-08-22",
      implemented_by: {Managoat.Runtimes.OpenCode, :prepare_sandbox, 3},
      reprobe: "`command -v opencode` on a fresh sandbox before provisioning runs.",
      delete_when: """
      opencode ships in the sprite base image at a version we choose. Note
      this also removes an exposure rather than only a delay: the install
      currently runs after `Provisioning.apply_network_policy/3`, so a
      `limited` environment has to allowlist the npm registry for it to
      succeed at all.
      """
    },
    %{
      id: :home_on_tmp,
      runtimes: ["gemini", "opencode"],
      summary: "two runtimes are moved to HOME=/tmp to dodge a failing rename",
      why: """
      gemini-cli aborts during init if it cannot rename
      `$HOME/.gemini/projects.json.tmp` onto `projects.json`. The sprite user
      appears to have write access to /home/sprite — `ls` and most writes go
      through — but a rename across that ACL boundary errors out. opencode
      hits the same boundary from the other direction: it cannot `git init` in
      $HOME because of work-tree permissions. Both are moved to /tmp, and
      every path Fountain writes for them follows.
      """,
      upstream: {:none, "sprite base-image filesystem permissions, ours to change"},
      measured_against: "sprite base image as of 2026-08-22",
      implemented_by: {Managoat.Runtimes.Layout, :home_env, 1},
      reprobe: """
      As the sprite user on a live sandbox: `touch /home/sprite/.probe.tmp &&
      mv /home/sprite/.probe.tmp /home/sprite/.probe`. A clean rename means
      the workaround is unnecessary.
      """,
      delete_when: """
      The sprite user can rename across /home/sprite. Then both rows in
      `Managoat.Runtimes.Layout` take the image's own home and `home_env/1`
      returns `[]` for every runtime — no other change is needed, which is
      the point of deriving the paths from it.
      """
    },
    %{
      id: :npm_global_bin_off_path,
      runtimes: ["claude", "codex"],
      summary: "installed ACP adapters are symlinked onto PATH by hand",
      why: """
      `npm prefix -g` on the sprite is inside the nvm tree, whose `bin/` is not
      on the default PATH: `command -v claude-agent-acp` after a successful
      global install returns nothing, and the spawn then fails with `command
      not found` — which reads like a protocol bug and is not one. So the
      install symlinks into `/home/sprite/.local/bin`, which is on PATH. bun
      has the identical problem, handled the same way in
      `OpenCode.prepare_sandbox/3`.
      """,
      upstream: {:none, "sprite base-image PATH, ours to change"},
      measured_against: "verified on a live sprite 2026-08-10, node v24.18.0",
      implemented_by: {Managoat.Runtimes.ACP, :install, 3},
      reprobe: """
      `npm install -g <anything with a bin>` on a fresh sandbox, then
      `command -v` it without the symlink.
      """,
      delete_when: """
      The sprite's default PATH includes npm's and bun's global bin
      directories. Both symlink steps go, here and in
      `OpenCode.prepare_sandbox/3`.
      """
    }
  ]

  @doc "Every recorded quirk, in declaration order."
  @spec all() :: [quirk()]
  def all, do: @quirks

  @doc "The quirks Fountain carries for one runtime."
  @spec for_runtime(String.t()) :: [quirk()]
  def for_runtime(runtime) when is_binary(runtime),
    do: Enum.filter(@quirks, &(runtime in &1.runtimes))

  @doc "One quirk by id, or nil."
  @spec get(atom()) :: quirk() | nil
  def get(id) when is_atom(id), do: Enum.find(@quirks, &(&1.id == id))

  @doc """
  Quirks with an upstream issue to watch, as `{id, url}` pairs — the ones
  whose deletion depends on somebody else. The rest are ours to remove
  whenever we decide to.
  """
  @spec upstream_tracked() :: [{atom(), String.t()}]
  def upstream_tracked do
    for %{id: id, upstream: url} <- @quirks, is_binary(url), do: {id, url}
  end
end
