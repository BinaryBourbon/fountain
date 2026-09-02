# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose) and needs none: every proxy test starts its own
# listener on port 0, its own in-memory store and its own Bandit origin, so
# nothing here is global and the modules run async.
ExUnit.start()
