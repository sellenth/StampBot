defmodule DragNStamp.Repo.Migrations.AddUniqueIndexOnTimestampsUrl do
  use Ecto.Migration

  # Clean up duplicates, then add the unique index
  def up do
    # Keep one row per URL, preferring entries that already have distilled_content,
    # then the most recent by inserted_at. Delete the rest.
    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY url
               ORDER BY (distilled_content IS NOT NULL) DESC,
                        inserted_at DESC,
                        id DESC
             ) AS rn
      FROM timestamps
    )
    DELETE FROM timestamps
    WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
    """)

    create unique_index(:timestamps, [:url], name: :timestamps_url_unique)
  end

  def down do
    drop_if_exists index(:timestamps, [:url], name: :timestamps_url_unique)
  end
end
