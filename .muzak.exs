%{
  default: [
    mutation_filter: fn files ->
      target_files = [
        "lib/fountain/crypto.ex",
        "lib/fountain/accounts/api_key.ex",
        "lib/fountain/environments/secret.ex",
        "lib/fountain/conversations/conversation.ex"
      ]

      files
      |> Enum.filter(fn file -> Enum.any?(target_files, &String.ends_with?(file, &1)) end)
      |> Enum.map(&{&1, nil})
    end
  ]
}
