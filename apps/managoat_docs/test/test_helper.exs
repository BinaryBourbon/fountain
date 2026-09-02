# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose) and needs none: everything a manual needs is on
# the `use Managoat.Docs` line of Managoat.Docs.Fixture in test/support.
# Nothing here writes application env, so nothing leaks into Fountain's
# suite when the umbrella root runs every app in one VM.
ExUnit.start()
