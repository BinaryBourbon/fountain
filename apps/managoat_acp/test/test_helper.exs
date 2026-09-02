# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose) and needs none: the peer takes its transport as a
# function, the policy is a map, and the ask timeout is an argument. Every
# test drives a peer against a writer that is a plain function, so the whole
# suite is async and stubs nothing.
ExUnit.start()
