# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose) and needs none: nothing here reads configuration.
# The one thing set at runtime, the fake runtime's observer, is set per test
# by whoever uses the fake.
#
# The sandbox seam is Managoat.Sandbox (the facade) and, for the tests that
# expect on the adapter behind it, Managoat.Sandbox.Sprites; both are copied
# here so a test can stub or expect on them.
Mimic.copy(Managoat.Sandbox)
Mimic.copy(Managoat.Sandbox.Sprites)

ExUnit.start()
