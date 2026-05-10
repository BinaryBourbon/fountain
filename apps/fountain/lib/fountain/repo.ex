defmodule Fountain.Repo do
  use Ecto.Repo,
    otp_app: :fountain,
    adapter: Ecto.Adapters.Postgres
end
