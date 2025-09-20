defmodule DragNStamp.Timestamp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "timestamps" do
    field :url, :string
    field :channel_name, :string
    field :submitter_username, :string
    field :content, :string
    field :distilled_content, :string
    field :video_id, :string
    field :video_title, :string
    field :video_description, :string
    field :video_thumbnail_url, :string
    field :video_duration_seconds, :integer
    field :video_published_at, :utc_datetime

    field :youtube_comment_status, Ecto.Enum,
      values: [:not_attempted, :pending, :succeeded, :failed, :auth_required],
      default: :not_attempted

    field :youtube_comment_error, :string
    field :youtube_comment_last_attempt_at, :utc_datetime
    field :youtube_comment_external_id, :string
    field :youtube_comment_dedupe_key, :string
    field :youtube_comment_attempts, :integer, default: 0

    timestamps()
  end

  def changeset(timestamp, attrs) do
    timestamp
    |> cast(attrs, [
      :url,
      :channel_name,
      :submitter_username,
      :content,
      :distilled_content,
      :video_id,
      :video_title,
      :video_description,
      :video_thumbnail_url,
      :video_duration_seconds,
      :video_published_at,
      :youtube_comment_status,
      :youtube_comment_error,
      :youtube_comment_last_attempt_at,
      :youtube_comment_external_id,
      :youtube_comment_dedupe_key,
      :youtube_comment_attempts
    ])
    |> validate_required([:url, :channel_name, :content])
    |> validate_format(:url, ~r/^https?:\/\/(.*youtube.*\/watch\?v=.*|youtu\.be\/.*)/,
      message: "must be a valid YouTube URL"
    )
    |> unique_constraint(:url)
  end
end
