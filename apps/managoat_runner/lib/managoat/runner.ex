defmodule Managoat.Runner do
  @moduledoc """
  The self-hosted runner: a `Managoat.Sandbox` adapter whose transport is a
  WebSocket that a daemon on the user's machine dials *out* to the platform.

  The pieces, in the order a request passes through them:

    * `Managoat.Runner.Adapter` implements `Managoat.Sandbox`; every callback
      is one request to the runner the sandbox name routes to;
    * `Managoat.Runner.Names` mints and parses those names
      (`runner-<32 hex>-<8 hex>`), the only place a runner id rides in the
      sandbox contract;
    * `Managoat.Runner.Connection` is the `WebSock` handler holding one
      daemon's socket: it frames requests, matches replies and forwards the
      daemon's stream frames to the owner of the command they belong to. Its
      moduledoc is the wire protocol;
    * `Managoat.Runner.Host` is what the platform running all of this has to
      supply: a registry of connections by runner id, plus the two
      notifications (alive, online/offline) it may want. `Managoat.Runner.Host.Local`
      is the reference implementation over a plain `Registry`;
    * `Managoat.Runner.FakeDaemon` is a daemon inside the BEAM speaking the
      exact protocol, for the conformance suite and for any consumer's tests.

  The host is named in config, `config :managoat_runner, host: MyApp.RunnerHost`,
  and read through `Managoat.Runner.Config`.
  """
end
