%{
  default: [
    mutation_filter: fn files ->
      IO.puts("DEBUG muzak files sample: #{inspect(Enum.take(files, 3))}")
      IO.puts("DEBUG total files: #{length(files)}")

      target_basenames = [
        "crypto.ex",
        "api_key.ex",
        "secret.ex",
        "conversation.ex"
      ]

      files
      |> Enum.filter(fn file ->
        basename = Path.basename(file)
        Enum.member?(target_basenames, basename)
      end)
      |> tap(fn matched -> IO.puts("DEBUG matched: #{inspect(matched)}") end)
      |> Enum.map(&{&1, nil})
    end
  ]
}
