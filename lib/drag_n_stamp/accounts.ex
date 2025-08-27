defmodule DragNStamp.Accounts do
  import Ecto.Query, warn: false
  alias DragNStamp.Repo
  alias DragNStamp.Accounts.User

  def find_or_create_user(%Ueberauth.Auth{} = auth) do
    user_data = %{
      email: auth.info.email,
      name: auth.info.name,
      picture: auth.info.image,
      provider: to_string(auth.provider),
      uid: auth.uid
    }

    %User{}
    |> User.changeset(user_data)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :picture, :updated_at]},
      conflict_target: [:provider, :uid],
      returning: true
    )
  end

  def get_user(id) do
    Repo.get(User, id)
  end
end