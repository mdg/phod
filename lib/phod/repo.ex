defmodule Phod.Repo do
  use Ecto.Repo,
    otp_app: :phod,
    adapter: Ecto.Adapters.Postgres
end
