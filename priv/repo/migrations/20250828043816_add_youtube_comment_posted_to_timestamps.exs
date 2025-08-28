defmodule DragNStamp.Repo.Migrations.AddYoutubeCommentPostedToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :youtube_comment_posted, :boolean, default: false, null: false
    end
  end
end
