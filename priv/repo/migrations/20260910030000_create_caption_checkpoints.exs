defmodule DragNStamp.Repo.Migrations.CreateCaptionCheckpoints do
  use Ecto.Migration

  def change do
    create table(:caption_checkpoints) do
      add :timestamp_id, references(:timestamps, on_delete: :delete_all), null: false
      add :input_hash, :string, size: 64, null: false
      add :chunk_index, :integer, null: false
      add :chapter_data, {:array, :map}, null: false
      add :model, :string, null: false
      add :model_version, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:caption_checkpoints, [:timestamp_id, :chunk_index])
  end
end
