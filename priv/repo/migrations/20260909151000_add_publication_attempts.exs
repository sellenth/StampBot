defmodule DragNStamp.Repo.Migrations.AddPublicationAttempts do
  use Ecto.Migration

  def change do
    create table(:publication_attempts) do
      add :timestamp_id, references(:timestamps, on_delete: :restrict), null: false
      add :account_key, :string, null: false
      add :authority, :string, null: false
      add :content_digest, :string, null: false
      add :attempt_number, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :attempted_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :external_id, :string
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:publication_attempts, [:account_key, :attempted_at])
    create unique_index(:publication_attempts, [:timestamp_id, :attempt_number])
  end
end
