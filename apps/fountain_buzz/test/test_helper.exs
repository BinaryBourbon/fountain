# This app's tests run in the umbrella's VM alongside Fountain's, against the
# same Repo and the same SQL Sandbox. `mix test` at the root starts every app,
# so ExUnit.start/0 here is a no-op when Fountain's helper ran first and the
# entry point when this app's suite is run alone.
ExUnit.start()

if Process.whereis(Fountain.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
end
