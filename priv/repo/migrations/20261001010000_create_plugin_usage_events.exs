defmodule DragNStamp.Repo.Migrations.CreatePluginUsageEvents do
  use Ecto.Migration

  def change do
    create table(:plugin_usage_events) do
      add :request_key, :uuid, null: false
      add :operation, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string
      add :actor_hash, :string, null: false
      add :identity_kind, :string, null: false
      add :session_hash, :string
      add :transport_hash, :string, null: false
      add :new_work, :boolean, null: false, default: false
      add :elapsed_ms, :integer, null: false, default: 0
      add :timestamp_id, references(:timestamps, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:plugin_usage_events, [:request_key])
    create index(:plugin_usage_events, [:inserted_at])
    create index(:plugin_usage_events, [:actor_hash, :inserted_at])
    create index(:plugin_usage_events, [:transport_hash, :inserted_at])
    create index(:plugin_usage_events, [:timestamp_id])
  end
end
