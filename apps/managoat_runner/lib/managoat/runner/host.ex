defmodule Managoat.Runner.Host do
  @moduledoc """
  What the platform running `Managoat.Runner` supplies: a way to reach a
  runner's connection process by id, and two notifications it may act on.

  The connection process and the adapter need exactly these things from
  their host, and none of them is protocol:

    * `c:register/2` — when a socket opens, register the *calling* process
      (the connection) under the runner id, with `meta`. A second connection
      for the same id is refused with `{:error, :already_registered}`, and
      the connection closes it with code 4409.
    * `c:unregister/1` — when the socket closes, from the connection process,
      before `c:presence/3` fires so a subscriber that looks the runner up on
      receipt sees the truth.
    * `c:whereis/1` — the connection process for a runner id, from any node,
      or `nil`. `Managoat.Runner.Connection.call/3` and `unsubscribe/3` route
      through it.
    * `c:online/0` — every runner id currently registered, with its `meta`.
      `Managoat.Runner.Adapter.list_all_names/0` walks them.
    * `c:heartbeat/1` — the runner is alive; sent every 20 seconds while the
      socket is up. A host that keeps a `last_seen_at` stamps it here.
    * `c:presence/3` — the runner went `:online` (registered) or `:offline`
      (unregistered), with the `meta` it registered with. A host with a
      roster to refresh broadcasts it here.

  `meta` is an opaque map: the host puts what it needs in it when the
  connection is opened (the `WebSock` init map's `:meta` key) and gets it
  back on `c:online/0` and `c:presence/3`. The library never reads a key
  from it.

  A host may send `{:runner_deleted, runner_id}` to the connection process
  (found through `c:whereis/1`); the connection closes the socket with code
  4404. That message is part of the contract between host and connection.

  `Managoat.Runner.Host.Local` is the reference implementation over a plain
  `Registry`, with the two notifications as no-ops. The library's own tests
  run against it, and so does a consumer without a cluster.
  """

  @type runner_id :: binary()
  @type meta :: map()

  @callback register(runner_id, meta) :: :ok | {:error, :already_registered}
  @callback unregister(runner_id) :: :ok
  @callback whereis(runner_id) :: pid() | nil
  @callback online() :: [{runner_id, meta}]
  @callback heartbeat(runner_id) :: :ok
  @callback presence(runner_id, :online | :offline, meta) :: :ok
end
