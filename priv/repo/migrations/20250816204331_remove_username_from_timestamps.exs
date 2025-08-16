defmodule DragNStamp.Repo.Migrations.RemoveUsernameFromTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      remove :username
    end
  end
end
