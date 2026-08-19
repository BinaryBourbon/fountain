defmodule Fountain.Repo.Migrations.AddTokenUsage do
  @moduledoc """
  Token usage per turn and per conversation (#827).

  `turns.usage` is the end-of-turn figure as the runtime reports it on the
  ACP `session/prompt` response — `{"input", "output", "cache_read",
  "cache_write"}` — null for turns that predate this or whose runtime does
  not report one. The two conversation columns are running sums of `input`
  and `output` over the conversation's turns, kept by the context as each
  turn ends, so a list never has to aggregate turns.
  """
  use Ecto.Migration

  def change do
    alter table(:turns) do
      add :usage, :map
    end

    alter table(:conversations) do
      add :usage_input_tokens, :bigint, null: false, default: 0
      add :usage_output_tokens, :bigint, null: false, default: 0
    end
  end
end
