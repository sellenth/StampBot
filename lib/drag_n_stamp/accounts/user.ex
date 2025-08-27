defmodule DragNStamp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :picture, :string
    field :provider, :string
    field :uid, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :picture, :provider, :uid])
    |> validate_required([:email, :provider, :uid])
    |> unique_constraint([:provider, :uid])
  end
end