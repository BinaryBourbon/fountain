[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  # Umbrella children carry their own .formatter.exs; without this the globs
  # below (root-relative) would never reach apps/. See #612.
  subdirectories: ["apps/*"],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs}",
    "ee/**/*.{ex,exs}"
  ]
]
