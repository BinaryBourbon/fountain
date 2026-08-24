defmodule Fountain.Repo.Migrations.AddOriginToTurns do
  use Ecto.Migration

  # Who opened the turn (#817). `user` is a prompt somebody sent; `autonomous`
  # is a turn the server opens for a background cycle the agent runs after its
  # prompt was answered — a Monitor firing, a scheduled wake-up — which arrives
  # over an ACP connection that now outlives the prompt. Additive and inert:
  # nothing writes `autonomous` until the connection moves to the wake (part 3
  # of #817); every existing row is a `user` turn, which is what it was.
  def change do
    alter table(:turns) do
      add :origin, :string, null: false, default: "user"
    end
  end
end
