defmodule DragNStamp.Repo.Migrations.UpdateCommentFieldsOnTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      remove :youtube_comment_posted
      add :youtube_comment_status, :string, null: false, default: "not_attempted"
      add :youtube_comment_error, :string
      add :youtube_comment_last_attempt_at, :utc_datetime
      add :youtube_comment_external_id, :string
      add :youtube_comment_dedupe_key, :string
      add :youtube_comment_attempts, :integer, null: false, default: 0
    end

    create unique_index(
             :timestamps,
             [:youtube_comment_dedupe_key],
             where: "youtube_comment_dedupe_key IS NOT NULL",
             name: :timestamps_youtube_comment_dedupe_key_unique
           )
  end
end

