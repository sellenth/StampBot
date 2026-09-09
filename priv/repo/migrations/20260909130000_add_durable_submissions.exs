defmodule DragNStamp.Repo.Migrations.AddDurableSubmissions do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    alter table(:timestamps) do
      add :processing_phase, :string, null: false, default: "queued"
    end

    execute(
      "UPDATE timestamps SET processing_phase = processing_status WHERE processing_status IN ('ready', 'failed')"
    )

    # Populate identity on legacy rows without deleting historical duplicates.
    # Canonical submission lookup prefers an existing ready result; new writes
    # are serialized per video ID by a PostgreSQL transaction advisory lock.
    execute("""
    UPDATE timestamps
    SET video_id = substring(url from '(?:[?&]v=|youtu[.]be/|youtube[.]com/(?:shorts|live|embed)/)([A-Za-z0-9_-]{11})(?:[?&#/]|$)')
    WHERE video_id IS NULL
    """)

    create index(:timestamps, [:processing_status, :updated_at])
  end

  def down do
    drop index(:timestamps, [:processing_status, :updated_at])

    alter table(:timestamps) do
      remove :processing_phase
    end

    Oban.Migration.down(version: 1)
  end
end
