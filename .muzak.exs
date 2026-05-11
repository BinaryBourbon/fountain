%{
  default: [
    mutation_filter: fn files ->
      target_files = [
        "apps/fountain/lib/fountain/crypto.ex",
        "apps/fountain/lib/fountain/accounts/api_key.ex",
        "apps/fountain/lib/fountain/environments/secret.ex",
        "apps/fountain/lib/fountain/conversations/conversation.ex"
      ]

      files
      |> Enum.filter(fn file -> Enum.any?(target_files, &String.ends_with?(file, &1)) end)
      |> Enum.map(&{&1, nil})
    end
  ]
}
