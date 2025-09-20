defmodule DragNStamp.Repo.Migrations.AddVideoMetadataToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :video_id, :string
      add :video_title, :string
      add :video_description, :text
      add :video_thumbnail_url, :string
      add :video_duration_seconds, :integer
      add :video_published_at, :utc_datetime
    end

    create index(:timestamps, [:video_id])
  end
end
