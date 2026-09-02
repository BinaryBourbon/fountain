# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose), and the one setting it reads has no default: a
# consumer that names no host gets an error, not a registry that quietly
# finds nothing. The suite runs against the reference host, so name it and
# start its registry here. The umbrella's config/config.exs names Fountain's
# host for the root run.
Application.put_env(:managoat_runner, :host, Managoat.Runner.Host.Local)
{:ok, _} = Managoat.Runner.Host.Local.start_link()

# The adapter is dispatched to through Managoat.Sandbox's adapter map; the
# library's tests that go through the facade (host_path) need it registered
# beside the three the sandbox library ships.
Application.put_env(
  :managoat_sandbox,
  :adapters,
  Map.put(Managoat.Sandbox.adapters(), :runner, Managoat.Runner.Adapter)
)

ExUnit.start()
