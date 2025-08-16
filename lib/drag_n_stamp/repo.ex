defmodule DragNStamp.Repo do
  use Ecto.Repo,
    otp_app: :drag_n_stamp,
    adapter: Ecto.Adapters.Postgres
end
