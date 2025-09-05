defmodule DragNStamp.Timestamp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "timestamps" do
    field :url, :string
    field :channel_name, :string
    field :submitter_username, :string
    field :content, :string
    field :distilled_content, :string

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
  end
end
