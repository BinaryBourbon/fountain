[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{lib,test}/**/*.{heex,ex,exs}",
    "priv/repo/migrations/*.exs",
    "priv/repo/seeds.exs"
  ]
]
