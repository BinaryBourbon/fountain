# Mimic copies the modules the adapter tests stub: the Sprites SDK and the
# Req client behind the E2B/Daytona adapters, plus the seams the facade test
# dispatches through.
Mimic.copy(Managoat.Sandbox.Sprites)
Mimic.copy(Managoat.Sandbox.Sprites.Client)
Mimic.copy(Managoat.Sandbox.Daytona.LogStream)
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(Req)

# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose). Managoat.Sandbox.Retry sleeps between attempts; 1ms
# keeps the retry-path tests fast without changing the logic under test. The
# umbrella's config/test.exs sets the same value for the root run.
Application.put_env(:managoat_sandbox, Managoat.Sandbox.Retry, base_ms: 1)

ExUnit.start()
