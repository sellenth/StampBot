defmodule DragNStamp.Repo.Migrations.CreateTimestamps do
  use Ecto.Migration

  def change do
    create table(:timestamps) do
      add :url, :string, null: false
      add :channel_name, :string, null: false
      add :username, :string, null: false
      add :content, :text, null: false

      timestamps()
    end

    create index(:timestamps, [:channel_name])
    create index(:timestamps, [:url])
  end
end
