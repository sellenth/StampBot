defmodule DragNStamp.Repo.Migrations.AddSubmitterUsernameToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :submitter_username, :string, null: false, default: "anonymous"
    end

    create index(:timestamps, [:submitter_username])
  end
end
